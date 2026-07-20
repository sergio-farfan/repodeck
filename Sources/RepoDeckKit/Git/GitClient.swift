import Foundation

/// Outcome of `GitClient.pushWithAutoRebase(in:)`: whether the push landed
/// on the first attempt or required a rebase-and-retry.
public enum PushOutcome: Sendable, Equatable {
    case pushed
    case rebasedAndPushed
}

/// A pre-operation HEAD snapshot recorded as a git ref, so it survives gc
/// and app restarts. Written by `GitClient.writeUndoSnapshot(in:)` before
/// the two operations where RepoDeck itself rewrites local history —
/// `pull()` and the auto-rebase branch of `pushWithAutoRebase` — and
/// consumed by `GitClient.restoreUndoSnapshot(_:expectedHead:in:)`.
public struct UndoSnapshot: Sendable, Equatable {
    /// "refs/repodeck/undo/<unix-ts>"
    public let refName: String
    /// Full HEAD OID at snapshot time.
    public let oid: String

    public init(refName: String, oid: String) {
        self.refName = refName
        self.oid = oid
    }
}

/// Stateless façade over the git CLI: every view model calls into `GitClient`
/// rather than shelling out directly. Composes `ProcessRunner` (subprocess
/// execution), `PorcelainParser` (status), and `LogParser` (log) into typed
/// git operations. No `Process`/argv details leak past this type.
public struct GitClient: Sendable {
    public var gitPath: String

    /// Output cap (bytes) passed to `status`'s `ProcessRunner.run` call.
    /// Public so tests can shrink it to exercise the truncation path without
    /// generating megabytes of fixture data.
    public var statusOutputLimit: Int = 4_000_000

    /// Output cap (bytes) passed to `diff`/`diffUntracked`/`diffCommit`'s
    /// `ProcessRunner.run` calls. Unlike `status`, a truncated diff is not
    /// usable even partially (8b will build byte-exact patches from this
    /// path), so the diff methods throw a `GitError` instead of returning a
    /// partial parse — see their doc comments. Public so tests can shrink it
    /// to exercise the truncation path without generating megabytes of
    /// fixture data.
    public var diffOutputLimit: Int = 10_000_000

    public init(gitPath: String = GitDefaults.gitPath) {
        self.gitPath = gitPath
    }

    /// `git -C <repo> status --porcelain=v2 --branch --untracked-files=all -z`
    ///
    /// Runs with `GIT_OPTIONAL_LOCKS=0` (never blocks on another git process
    /// holding the index lock) and a `statusOutputLimit`-byte output cap; a
    /// truncated read is passed through to `PorcelainParser` rather than
    /// treated as failure.
    public func status(in repo: URL) async throws -> RepoStatus {
        let result = try await run(
            ["status", "--porcelain=v2", "--branch", "--untracked-files=all", "-z"],
            in: repo,
            environment: ["GIT_OPTIONAL_LOCKS": "0"],
            maxOutputBytes: statusOutputLimit
        )
        return PorcelainParser.parse(result.stdout, truncated: result.outputTruncated)
    }

    /// `git -C <repo> log -n <limit> --pretty=format:%H%x1f%h%x1f%s%x1f%an%x1f%aI%x1f%D%x1e`
    ///
    /// Special case: a brand-new repo with no commits yet exits 128 with
    /// stderr containing "does not have any commits" — that is not an error
    /// condition for us, it just means an empty history. See `runLogCommand`.
    public func log(in repo: URL, limit: Int = 100) async throws -> [Commit] {
        try await runLogCommand(["log", "-n", "\(limit)", "--pretty=format:\(Self.logFormat)"], in: repo)
    }

    /// `git -C <repo> log -n <limit> --pretty=format:<same format as `log`>`
    /// plus, by `query.field`:
    /// - `.message` → `--grep=<text> -i`
    /// - `.author` → `--author=<text> -i`
    /// - `.content` → `-G<text>` (pickaxe: commits that add/remove a line matching `text`)
    /// - `.path` → `-- <text>` (pathspec, always LAST in argv)
    ///
    /// `query.text` is trimmed; if empty after trimming, no filter is added
    /// and this behaves exactly like `log` (full recent log). Shares the
    /// exit-128 empty-repo handling with `log` via `runLogCommand`.
    public func searchLog(_ query: HistorySearchQuery, in repo: URL, limit: Int = 100) async throws -> [Commit] {
        var arguments = ["log", "-n", "\(limit)", "--pretty=format:\(Self.logFormat)"]
        let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            switch query.field {
            case .message:
                arguments += ["--grep=\(text)", "-i"]
            case .author:
                arguments += ["--author=\(text)", "-i"]
            case .content:
                arguments += ["-G\(text)"]
            case .path:
                arguments += ["--", text]
            }
        }
        return try await runLogCommand(arguments, in: repo)
    }

    /// `git -C <repo> add -- <paths>` (also stages deletions of tracked files).
    public func stage(_ paths: [String], in repo: URL) async throws {
        try await runVoid(["add", "--"] + paths, in: repo)
    }

    /// `git -C <repo> restore --staged -- <paths>`
    ///
    /// Known v1 edge case: `git restore --staged` fails in a repo with no
    /// commits yet — there is no HEAD to restore the index against. Callers
    /// should only invoke `unstage` once at least one commit exists.
    public func unstage(_ paths: [String], in repo: URL) async throws {
        try await runVoid(["restore", "--staged", "--"] + paths, in: repo)
    }

    /// `git -C <repo> add -A`
    public func stageAll(in repo: URL) async throws {
        try await runVoid(["add", "-A"], in: repo)
    }

    /// `git -C <repo> commit -m <message>`
    public func commit(message: String, in repo: URL) async throws {
        try await runVoid(["commit", "-m", message], in: repo)
    }

    /// `git -C <repo> pull`
    public func pull(in repo: URL) async throws {
        try await runVoid(["pull"], in: repo, timeout: Self.syncTimeout)
    }

    /// `git -C <repo> push`
    public func push(in repo: URL) async throws {
        try await runVoid(["push"], in: repo, timeout: Self.syncTimeout)
    }

    /// `git push`, with automatic recovery from a non-fast-forward
    /// rejection: on rejection, runs `git pull --rebase --autostash` and
    /// retries the push exactly once. A first-push failure that is not a
    /// rejection is rethrown unchanged, with no rebase attempted; the
    /// retry's own failure is rethrown unchanged after the rebase has
    /// already completed. If the rebase itself fails (e.g. conflicts), a
    /// best-effort `git rebase --abort` restores the pre-pull state before
    /// the pull's error is rethrown, so the repo is never left mid-rebase;
    /// the abort's own result is ignored because it fails harmlessly when
    /// the pull never actually started a rebase.
    public func pushWithAutoRebase(in repo: URL) async throws -> PushOutcome {
        do {
            try await runVoid(["push"], in: repo, timeout: Self.syncTimeout)
            return .pushed
        } catch let error as GitError where error.isNonFastForwardPushRejection {
            do {
                try await runVoid(["pull", "--rebase", "--autostash"], in: repo, timeout: Self.syncTimeout)
            } catch let pullError as GitError {
                try? await runVoid(["rebase", "--abort"], in: repo)
                throw pullError
            }
            try await runVoid(["push"], in: repo, timeout: Self.syncTimeout)
            return .rebasedAndPushed
        }
    }

    /// `git -C <repo> fetch`
    ///
    /// `priority` defaults to `.interactive`; background callers (auto-fetch,
    /// integrations polling) pass `.background` so they queue behind
    /// interactive work rather than competing with it for limiter slots.
    public func fetch(in repo: URL, priority: SubprocessPriority = .interactive) async throws {
        try await runVoid(["fetch"], in: repo, priority: priority, timeout: Self.fetchTimeout)
    }

    // MARK: - Stash

    /// `git -C <repo> stash list -z --format=%gd%x1f%gs%x1f%cI` -> `StashParser.parse`
    public func stashList(in repo: URL) async throws -> [StashEntry] {
        let result = try await run(["stash", "list", "-z", "--format=\(Self.stashFormat)"], in: repo)
        return StashParser.parse(String(decoding: result.stdout, as: UTF8.self))
    }

    /// `git -C <repo> stash push [--include-untracked] [-m <message>]`
    public func stashPush(message: String?, includeUntracked: Bool, in repo: URL) async throws {
        var arguments = ["stash", "push"]
        if includeUntracked {
            arguments.append("--include-untracked")
        }
        if let message {
            arguments += ["-m", message]
        }
        try await runVoid(arguments, in: repo)
    }

    /// `git -C <repo> stash apply stash@{index}`
    public func stashApply(_ index: Int, in repo: URL) async throws {
        try await runVoid(["stash", "apply", Self.stashSelector(index)], in: repo)
    }

    /// `git -C <repo> stash pop stash@{index}`
    public func stashPop(_ index: Int, in repo: URL) async throws {
        try await runVoid(["stash", "pop", Self.stashSelector(index)], in: repo)
    }

    /// `git -C <repo> stash drop stash@{index}`
    public func stashDrop(_ index: Int, in repo: URL) async throws {
        try await runVoid(["stash", "drop", Self.stashSelector(index)], in: repo)
    }

    // MARK: - Diff

    /// `-c` pins prepended to every diff/show invocation below, ahead of the
    /// subcommand, so filenames parse cleanly regardless of the user's own
    /// `~/.gitconfig` (empirically, git 2.50.1):
    /// - `core.quotepath=false` — the default (`true`) octal-escapes and
    ///   quotes non-ASCII paths ("a/\343\203...") — `DiffParser` would parse
    ///   that literally and show a bogus rename.
    /// - `diff.noprefix=false` — `true` drops the `a/`/`b/` prefixes, and for
    ///   constructs with no `---`/`+++` lines to fall back on (a pure rename
    ///   with no content change, or a binary file), the `diff --git` line
    ///   becomes the sole path source and unparseable — the file is silently
    ///   dropped.
    /// - `diff.mnemonicPrefix=false` — `true` emits `i/`/`w/`/`c/` prefixes
    ///   instead of `a/`/`b/`, which `DiffParser` treats as distinct old/new
    ///   paths — a plain modification renders as a bogus rename.
    ///
    /// Three explicit `-c` pairs (not `--default-prefix`) for robustness
    /// across older git versions.
    private static let diffConfigPins = [
        "-c", "core.quotepath=false",
        "-c", "diff.noprefix=false",
        "-c", "diff.mnemonicPrefix=false",
    ]

    /// Working-tree diff for one file. `staged=false` -> `git diff --no-ext-diff -- <path>`
    /// (unstaged); `staged=true` -> `git diff --no-ext-diff --staged -- <path>`. Untracked
    /// files have no diff target — callers detect untracked (via `status`) and use
    /// `diffUntracked` instead. `--no-ext-diff` keeps a user's configured external
    /// difftool from hijacking the output; no `--color` is passed, which is enough — git
    /// only colors output for a TTY, and a piped subprocess never is one. `diffConfigPins`
    /// (see above) are prepended so path parsing is stable regardless of the user's config.
    ///
    /// Capped at `diffOutputLimit` bytes; a truncated result throws a `GitError` (see
    /// `diffTooLargeError`) rather than parsing a partial diff.
    ///
    /// Returns `nil` when the parse yields no file (no changes for that path).
    public func diff(path: String, staged: Bool, in repo: URL) async throws -> FileDiff? {
        var arguments = Self.diffConfigPins + ["diff", "--no-ext-diff"]
        if staged {
            arguments.append("--staged")
        }
        arguments += ["--", path]
        let result = try await run(arguments, in: repo, maxOutputBytes: diffOutputLimit)
        if result.outputTruncated {
            throw diffTooLargeError(arguments, in: repo)
        }
        return DiffParser.parse(String(decoding: result.stdout, as: UTF8.self)).first
    }

    /// `git diff --no-ext-diff --no-index -- /dev/null <path>` for an untracked file, so it
    /// shows as an all-addition diff. `--no-index` exits 1 whenever the two sides differ —
    /// for an untracked file that is always true, so exit 1 is SUCCESS here, not failure;
    /// any other nonzero exit still throws. The returned `FileDiff`'s `newPath` is rewritten
    /// to the repo-relative `path` passed in, not whatever git echoes back on `+++`.
    ///
    /// Capped at `diffOutputLimit` bytes; a truncated result throws a `GitError` (see
    /// `diffTooLargeError`) rather than parsing a partial diff.
    public func diffUntracked(path: String, in repo: URL) async throws -> FileDiff? {
        let arguments = Self.diffConfigPins + ["diff", "--no-ext-diff", "--no-index", "--", "/dev/null", path]
        let result = try await run(
            arguments,
            in: repo,
            maxOutputBytes: diffOutputLimit,
            toleratedExitCodes: [1]
        )
        if result.outputTruncated {
            throw diffTooLargeError(arguments, in: repo)
        }
        guard let diff = DiffParser.parse(String(decoding: result.stdout, as: UTF8.self)).first else {
            return nil
        }
        return FileDiff(oldPath: diff.oldPath, newPath: path, isBinary: diff.isBinary, hunks: diff.hunks)
    }

    /// `git show --no-ext-diff --format= <oid>` unified diff for a whole commit -> all
    /// files' `FileDiff`s. The empty `--format=` suppresses the commit header/message,
    /// leaving just the diff. Merge commits show nothing by default from `git show` —
    /// acceptable for v1.
    ///
    /// Capped at `diffOutputLimit` bytes; a truncated result throws a `GitError` (see
    /// `diffTooLargeError`) rather than parsing a partial diff.
    public func diffCommit(_ oid: String, in repo: URL) async throws -> [FileDiff] {
        let arguments = Self.diffConfigPins + ["show", "--no-ext-diff", "--format=", oid]
        let result = try await run(arguments, in: repo, maxOutputBytes: diffOutputLimit)
        if result.outputTruncated {
            throw diffTooLargeError(arguments, in: repo)
        }
        return DiffParser.parse(String(decoding: result.stdout, as: UTF8.self))
    }

    /// Shared "diff too large" error for the three diff methods above, thrown
    /// when `run`'s `outputTruncated` comes back true. `run` treats
    /// truncation as a non-error result (needed by `status`, which returns a
    /// partial-but-usable parse) — but an unbounded diff (a 50k-line lockfile
    /// diff) both risks freezing the UI and, since 8b will build byte-exact
    /// patches from this exact parse path, must never be handed to
    /// `DiffParser` as a silently-partial hunk. `command` mirrors `run`'s own
    /// `commandString(fullArguments)` (the `-C <repo>`-prefixed argv that was
    /// actually executed) so the thrown error reads like any other `GitError`.
    private func diffTooLargeError(_ arguments: [String], in repo: URL) -> GitError {
        GitError(
            command: commandString(["-C", repo.path] + arguments),
            exitCode: -1,
            stderr: "diff too large to display (over \(diffOutputLimit / 1_000_000) MB)"
        )
    }

    // MARK: - Hunk staging

    /// Applies `patch` to the index via `git apply --cached [--reverse]
    /// --whitespace=nowarn -` (patch on stdin). `cached` true stages (or,
    /// with reverse, unstages) without touching the worktree. Throws
    /// GitError on a failed apply (e.g. the hunk no longer applies because
    /// the file changed). Does NOT pin `diffConfigPins` — this reads the
    /// patch `PatchBuilder` generated, not git's own diff output, so those
    /// path-parsing pins are irrelevant here.
    public func applyPatch(_ patch: String, cached: Bool, reverse: Bool, in repo: URL) async throws {
        var arguments = ["apply"]
        if cached {
            arguments.append("--cached")
        }
        if reverse {
            arguments.append("--reverse")
        }
        arguments += ["--whitespace=nowarn", "-"]
        try await runVoid(arguments, in: repo, stdin: Data(patch.utf8))
    }

    // MARK: - Identity

    /// Effective commit identity for `repo`: `git config user.name` +
    /// `git config user.email`, each resolved the way git itself would
    /// (local config overriding global). `git config <key>` exits 1 with
    /// empty stdout when the key is unset anywhere — that is "not
    /// configured", not a failure, so exit 1 is tolerated (same mechanism
    /// as `diffUntracked`) and a blank trimmed value becomes a nil field.
    public func configuredIdentity(in repo: URL) async throws -> GitIdentity {
        let name = try await configValue("user.name", in: repo)
        let email = try await configValue("user.email", in: repo)
        return GitIdentity(name: name, email: email)
    }

    /// `git config <key>` -> trimmed value, nil when unset (exit 1) or set
    /// to an empty/whitespace-only string.
    private func configValue(_ key: String, in repo: URL) async throws -> String? {
        let result = try await run(["config", key], in: repo, toleratedExitCodes: [1])
        let value = String(decoding: result.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    // MARK: - Undo snapshots
    //
    // One-level undo for the two operations where RepoDeck itself rewrites
    // local history: `pull()` and the auto-rebase branch of
    // `pushWithAutoRebase`. A snapshot is a git ref, not in-memory state, so
    // it survives `git gc` and app restarts. Exactly one snapshot exists per
    // repo at a time — every write prunes all prior `refs/repodeck/undo/*`
    // first — so there is never more than one ref to clean up or reason
    // about.

    /// Full OID of HEAD. `git rev-parse HEAD`.
    public func headOID(in repo: URL) async throws -> String {
        let result = try await run(["rev-parse", "HEAD"], in: repo)
        return String(decoding: result.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Prunes ALL existing `refs/repodeck/undo/*` refs (exactly one
    /// snapshot per repo, newest wins), then records HEAD under a fresh
    /// ref — `refs/repodeck/undo/<unix-ts>` — via `git update-ref`, where
    /// the timestamp is seconds since epoch at the moment of the call.
    public func writeUndoSnapshot(in repo: URL) async throws -> UndoSnapshot {
        try await pruneUndoSnapshots(in: repo)
        let oid = try await headOID(in: repo)
        let refName = "refs/repodeck/undo/\(Int(Date().timeIntervalSince1970))"
        try await runVoid(["update-ref", refName, oid], in: repo)
        return UndoSnapshot(refName: refName, oid: oid)
    }

    /// Restores HEAD to `snapshot` with `git reset --keep <oid>` — `--keep`
    /// (never `--hard`) preserves uncommitted work, and git itself refuses
    /// with a non-zero exit if the reset would clobber local modifications
    /// to a file that differs between the snapshot and current HEAD.
    ///
    /// Guard: before touching anything, compares current HEAD to
    /// `expectedHead` (the HEAD the caller observed right after the
    /// snapshotted operation completed). On mismatch — some other operation
    /// moved HEAD again since then — throws a `GitError` (stderr
    /// "repository has moved on since the snapshot", exitCode -1, command
    /// "git reset --keep") WITHOUT resetting or touching the snapshot ref.
    ///
    /// On success, deletes the snapshot ref.
    public func restoreUndoSnapshot(_ snapshot: UndoSnapshot, expectedHead: String, in repo: URL) async throws {
        let currentHead = try await headOID(in: repo)
        guard currentHead == expectedHead else {
            throw GitError(
                command: "git reset --keep",
                exitCode: -1,
                stderr: "repository has moved on since the snapshot"
            )
        }
        try await runVoid(["reset", "--keep", snapshot.oid], in: repo)
        await discardUndoSnapshot(snapshot, in: repo)
    }

    /// Deletes the snapshot ref — best effort, used both after a successful
    /// restore and when a newer operation supersedes an unused snapshot.
    /// `git update-ref -d <refName>`; any failure (e.g. the ref is already
    /// gone) is ignored.
    public func discardUndoSnapshot(_ snapshot: UndoSnapshot, in repo: URL) async {
        try? await runVoid(["update-ref", "-d", snapshot.refName], in: repo)
    }

    /// Deletes every existing `refs/repodeck/undo/*` ref via
    /// `git for-each-ref` + `update-ref -d`, so `writeUndoSnapshot` never
    /// leaves more than the one it is about to create.
    private func pruneUndoSnapshots(in repo: URL) async throws {
        let result = try await run(["for-each-ref", "--format=%(refname)", "refs/repodeck/undo"], in: repo)
        let refs = String(decoding: result.stdout, as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
        for ref in refs {
            try? await runVoid(["update-ref", "-d", ref], in: repo)
        }
    }

    // MARK: - Timeouts
    //
    // Network operations get a deadline so a hung remote can't wedge a
    // subprocess (and its limiter slot) forever; local operations
    // (status/log/stage/commit/etc.) have no timeout.

    static let fetchTimeout: Duration = .seconds(90)
    static let syncTimeout: Duration = .seconds(300)

    // MARK: - Private helpers

    /// Pretty-format shared by `log` and `searchLog`, kept in exactly one
    /// place so both stay in lockstep with `LogParser`'s field layout.
    private static let logFormat = "%H%x1f%h%x1f%s%x1f%an%x1f%aI%x1f%D%x1e"

    /// Format for `stashList`, kept in lockstep with `StashParser`'s field
    /// layout. Deliberately has no `%x1e` — `stashList` passes `-z`, which
    /// NUL-terminates each record itself; `%x1e` is only needed for `log`,
    /// which has no equivalent `-z` record terminator.
    private static let stashFormat = "%gd%x1f%gs%x1f%cI"

    /// `stash@{<index>}` — the selector `stashApply`/`stashPop`/`stashDrop`
    /// pass on argv.
    private static func stashSelector(_ index: Int) -> String {
        "stash@{\(index)}"
    }

    /// Runs a `git log`-shaped `arguments` list and parses the shared
    /// pretty-format output with `LogParser`.
    ///
    /// Special case, shared by `log` and `searchLog`: a brand-new repo (or a
    /// search that matches nothing on a fresh repo) with no commits yet
    /// exits 128 with stderr containing "does not have any commits" — that
    /// is not an error condition for us, it just means an empty history.
    private func runLogCommand(_ arguments: [String], in repo: URL) async throws -> [Commit] {
        do {
            let result = try await run(arguments, in: repo)
            return LogParser.parse(String(decoding: result.stdout, as: UTF8.self))
        } catch let error as GitError {
            if error.exitCode == 128, error.stderr.contains("does not have any commits") {
                return []
            }
            throw error
        }
    }

    /// Runs `git -C <repo> <arguments>` and throws `GitError` on any non-zero
    /// exit, carrying the full command string and stderr verbatim.
    ///
    /// A timed-out result always throws — unlike `outputTruncated`, a
    /// timeout is never treated as success — with a `GitError.stderr` that
    /// leads with "timed out after \(seconds)s" followed by the child's own
    /// stderr (if any) on a new line.
    /// `toleratedExitCodes` lets a caller treat specific nonzero exits as
    /// success without losing the captured stdout — needed by
    /// `diffUntracked`, where `git diff --no-index` exits 1 (not 0) whenever
    /// the two sides differ, which for an untracked file is the expected,
    /// successful case, not a failure.
    private func run(
        _ arguments: [String],
        in repo: URL,
        environment: [String: String] = [:],
        maxOutputBytes: Int? = nil,
        priority: SubprocessPriority = .interactive,
        timeout: Duration? = nil,
        toleratedExitCodes: Set<Int32> = [],
        stdin: Data? = nil
    ) async throws -> ProcessResult {
        let fullArguments = ["-C", repo.path] + arguments
        let result = try await ProcessRunner.run(
            gitPath,
            arguments: fullArguments,
            environment: environment,
            maxOutputBytes: maxOutputBytes,
            priority: priority,
            timeout: timeout,
            stdin: stdin
        )
        if result.timedOut {
            let seconds = timeout?.components.seconds ?? 0
            var stderr = "timed out after \(seconds)s"
            if !result.stderr.isEmpty {
                stderr += "\n" + result.stderr
            }
            throw GitError(
                command: commandString(fullArguments),
                exitCode: result.exitCode,
                stderr: stderr
            )
        }
        // `ProcessRunner` enforces `maxOutputBytes` by SIGTERM-ing the child,
        // which makes `terminationStatus` a nonzero signal exit (15) rather
        // than 0 — that is expected, not a failure. Only `status` and the
        // `diff`/`diffUntracked`/`diffCommit` methods pass `maxOutputBytes`,
        // so this can't mask a real failure of any other command. Unlike
        // `status` (which hands a truncated-but-partial parse to
        // `PorcelainParser`), the diff methods treat `outputTruncated` as
        // their own throw condition after this returns — see
        // `diffTooLargeError`.
        guard result.exitCode == 0 || result.outputTruncated || toleratedExitCodes.contains(result.exitCode) else {
            throw GitError(
                command: commandString(fullArguments),
                exitCode: result.exitCode,
                stderr: result.stderr
            )
        }
        return result
    }

    /// Convenience for commands whose stdout the caller never inspects.
    private func runVoid(
        _ arguments: [String],
        in repo: URL,
        priority: SubprocessPriority = .interactive,
        timeout: Duration? = nil,
        stdin: Data? = nil
    ) async throws {
        _ = try await run(arguments, in: repo, priority: priority, timeout: timeout, stdin: stdin)
    }

    private func commandString(_ arguments: [String]) -> String {
        (["git"] + arguments).joined(separator: " ")
    }
}
