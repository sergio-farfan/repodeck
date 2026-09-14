import Foundation
import CryptoKit

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
    /// Worktree/branch-scoped reference with a unique snapshot suffix.
    public let refName: String
    /// Full HEAD OID at snapshot time.
    public let oid: String
    public let branchRef: String?
    public let worktreeGitDir: String?

    public init(refName: String, oid: String, branchRef: String? = nil, worktreeGitDir: String? = nil) {
        self.refName = refName
        self.oid = oid
        self.branchRef = branchRef
        self.worktreeGitDir = worktreeGitDir
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
        try await runLogCommand(["log", "--no-color", "--no-show-signature", "--encoding=UTF-8", "-n", "\(limit)", "--pretty=format:\(Self.logFormat)"], in: repo)
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
        var arguments = ["log", "--no-color", "--no-show-signature", "--encoding=UTF-8", "-n", "\(limit)", "--pretty=format:\(Self.logFormat)"]
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
        guard !paths.isEmpty else { return }
        try await runVoid(["--literal-pathspecs", "add", "--"] + paths, in: repo)
    }

    /// `git -C <repo> restore --staged -- <paths>`
    ///
    /// An unborn branch has no HEAD; remove entries from its index instead,
    /// preserving all worktree files.
    public func unstage(_ paths: [String], in repo: URL) async throws {
        guard !paths.isEmpty else { return }
        let head = try await run(["rev-parse", "--verify", "--quiet", "HEAD"], in: repo, toleratedExitCodes: [1])
        if head.exitCode == 1 {
            // The index can differ from a file edited again after staging.
            // Force only the index removal; --cached preserves worktree bytes.
            try await runVoid(["--literal-pathspecs", "rm", "--cached", "--force", "-r", "--"] + paths, in: repo)
        } else {
            try await runVoid(["--literal-pathspecs", "restore", "--staged", "--"] + paths, in: repo)
        }
    }

    /// A rename's source and destination are one user-visible change.
    public func unstage(_ change: FileChange, in repo: URL) async throws {
        let paths = change.statusLetter == "R" ? [change.originalPath, change.path].compactMap { $0 } : [change.path]
        try await unstage(paths, in: repo)
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
    /// best-effort `git rebase --abort` attempts to restore the pre-pull
    /// state before the pull's error is rethrown. Abort can fail, and
    /// autostash restoration may leave conflicts or a recoverable stash;
    /// callers must refresh operation state and stashes after failure.
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

    /// Each entry includes its immutable OID alongside the displayed reflog index.
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
        try await stashApply(stashEntry(at: index, in: repo), in: repo)
    }

    /// `git -C <repo> stash pop stash@{index}`
    public func stashPop(_ index: Int, in repo: URL) async throws {
        try await stashPop(stashEntry(at: index, in: repo), in: repo)
    }

    /// `git -C <repo> stash drop stash@{index}`
    public func stashDrop(_ index: Int, in repo: URL) async throws {
        try await stashDrop(stashEntry(at: index, in: repo), in: repo)
    }

    public func stashApply(_ entry: StashEntry, in repo: URL) async throws {
        let oid = try stashOID(entry)
        try await runVoid(["stash", "apply", "--", oid], in: repo)
    }

    public func stashPop(_ entry: StashEntry, in repo: URL) async throws {
        // Applying by OID cannot accidentally restore a newer stash. Keep the
        // entry on any application failure, matching git stash pop semantics.
        _ = try await currentStashSelector(for: entry, in: repo)
        try await stashApply(entry, in: repo)
        try await stashDrop(entry, in: repo)
    }

    public func stashDrop(_ entry: StashEntry, in repo: URL) async throws {
        let selector = try await currentStashSelector(for: entry, in: repo)
        try await runVoid(["stash", "drop", "--", selector], in: repo)
    }

    private func stashEntry(at index: Int, in repo: URL) async throws -> StashEntry {
        guard let entry = try await stashList(in: repo).first(where: { $0.index == index }) else {
            throw staleStashError()
        }
        return entry
    }

    private func stashOID(_ entry: StashEntry) throws -> String {
        guard let oid = entry.oid, [40, 64].contains(oid.count), oid.allSatisfy({ $0.isHexDigit }) else {
            throw staleStashError()
        }
        return oid
    }

    private func currentStashSelector(for entry: StashEntry, in repo: URL) async throws -> String {
        let oid = try stashOID(entry)
        let matches = try await stashList(in: repo).filter { $0.oid == oid }
        guard matches.count == 1, let current = matches.first else { throw staleStashError() }
        let selector = Self.stashSelector(current.index)
        let result = try await run(["rev-parse", "--verify", selector], in: repo)
        guard Self.outputLine(result.stdout) == oid else { throw staleStashError() }
        return selector
    }

    private func staleStashError() -> GitError {
        GitError(command: "git stash", exitCode: -1, stderr: "The selected stash changed or is no longer available. Refresh the stash list and try again.")
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
    /// difftool from hijacking the output. Color and text conversion are explicitly
    /// disabled because these diffs also supply index patches. `diffConfigPins`
    /// make path prefixes stable regardless of the user's config.
    ///
    /// Capped at `diffOutputLimit` bytes; a truncated result throws a `GitError` (see
    /// `diffTooLargeError`) rather than parsing a partial diff.
    ///
    /// Returns `nil` when the parse yields no file (no changes for that path).
    public func diff(path: String, staged: Bool, in repo: URL) async throws -> FileDiff? {
        var arguments = ["--literal-pathspecs"] + Self.diffConfigPins + ["diff", "--no-ext-diff", "--no-color", "--no-textconv"]
        if staged {
            arguments.append("--staged")
        }
        arguments += ["--", path]
        let result = try await run(arguments, in: repo, maxOutputBytes: diffOutputLimit)
        if result.outputTruncated {
            throw diffTooLargeError(arguments, in: repo)
        }
        return DiffParser.parse(result.stdout).first
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
        let arguments = Self.diffConfigPins + ["diff", "--no-ext-diff", "--no-color", "--no-textconv", "--no-index", "--", "/dev/null", path]
        let result = try await run(
            arguments,
            in: repo,
            maxOutputBytes: diffOutputLimit,
            toleratedExitCodes: [1]
        )
        if result.outputTruncated {
            throw diffTooLargeError(arguments, in: repo)
        }
        guard let diff = DiffParser.parse(result.stdout).first else {
            return nil
        }
        return FileDiff(oldPath: diff.oldPath, newPath: path, isBinary: diff.isBinary, hunks: diff.hunks,
                        oldMode: diff.oldMode, newMode: diff.newMode, isLosslessUTF8: diff.isLosslessUTF8)
    }

    /// `git show --no-ext-diff --format= <oid>` unified diff for a whole commit -> all
    /// files' `FileDiff`s. The empty `--format=` suppresses the commit header/message,
    /// leaving just the diff. Merge commits show nothing by default from `git show` —
    /// acceptable for v1.
    ///
    /// Capped at `diffOutputLimit` bytes; a truncated result throws a `GitError` (see
    /// `diffTooLargeError`) rather than parsing a partial diff.
    public func diffCommit(_ oid: String, in repo: URL) async throws -> [FileDiff] {
        let arguments = Self.diffConfigPins + ["show", "--no-ext-diff", "--no-color", "--no-textconv", "--format=", oid, "--"]
        let result = try await run(arguments, in: repo, maxOutputBytes: diffOutputLimit)
        if result.outputTruncated {
            throw diffTooLargeError(arguments, in: repo)
        }
        return DiffParser.parse(result.stdout)
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

    /// Effective `user.name` and `user.email` configuration values across Git
    /// scopes. These editable defaults do not include `author.*` or author
    /// environment overrides; use `effectiveCommitAuthor` for a new commit.
    /// Missing or blank configuration values are represented by nil fields.
    public func configuredIdentity(in repo: URL) async throws -> GitIdentity {
        let name = try await configValue("user.name", in: repo)
        let email = try await configValue("user.email", in: repo)
        return GitIdentity(name: name, email: email)
    }

    /// Resolves the author Git would use for an ordinary new commit, using the
    /// same executable and inherited environment as `commit(message:in:)`.
    /// Git applies author-specific configuration, environment overrides, and
    /// its own identity normalization. This read does not change configuration.
    /// Author-preserving operations such as amend/rebase can use an old author.
    public func effectiveCommitAuthor(in repo: URL) async throws -> GitIdentity {
        let result = try await run(["var", "GIT_AUTHOR_IDENT"], in: repo,
                                   maxOutputBytes: 64 * 1024, timeout: .seconds(10))
        guard !result.outputTruncated else {
            throw GitError(command: "git var GIT_AUTHOR_IDENT", exitCode: result.exitCode,
                           stderr: "Git author output exceeded the 64 KiB limit.")
        }
        guard var output = String(data: result.stdout, encoding: .utf8) else {
            throw GitError(command: "git var GIT_AUTHOR_IDENT", exitCode: -1,
                           stderr: "Git returned an author identity containing text outside UTF-8.")
        }
        func malformed() -> GitError {
            GitError(command: "git var GIT_AUTHOR_IDENT", exitCode: -1,
                     stderr: "Git returned an unexpected author identity format.")
        }
        // Parse from the timestamp suffix so spaces and punctuation inside
        // the name/email stay exactly as Git emitted them.
        guard output.last == "\n" else { throw malformed() }
        output.removeLast()
        guard !output.contains("\n"), !output.utf8.contains(0),
              let timezoneStart = output.lastIndex(of: " "),
              let timestampStart = output[..<timezoneStart].lastIndex(of: " ") else { throw malformed() }
        let timezone = output[output.index(after: timezoneStart)...]
        let timestamp = output[output.index(after: timestampStart)..<timezoneStart]
        let digits = timestamp.first == "-" ? timestamp.dropFirst() : timestamp
        guard timezone.utf8.count == 5, timezone.first == "+" || timezone.first == "-",
              timezone.dropFirst().utf8.allSatisfy({ (48...57).contains($0) }),
              !digits.isEmpty, digits.utf8.allSatisfy({ (48...57).contains($0) }) else { throw malformed() }
        let identity = output[..<timestampStart]
        guard identity.last == ">", let opening = identity.lastIndex(of: "<"), opening > identity.startIndex,
              identity[identity.index(before: opening)] == " " else { throw malformed() }
        let name = String(identity[..<identity.index(before: opening)])
        let email = String(identity[identity.index(after: opening)..<identity.index(before: identity.endIndex)])
        guard !name.isEmpty, !name.contains("<"), !name.contains(">"),
              !email.contains("<"), !email.contains(">") else { throw malformed() }
        return GitIdentity(name: name, email: email)
    }

    /// Reads only the selected configuration scope, including files that scope
    /// includes. A missing repository value does not fall back to the global one.
    public func configuredIdentity(in repo: URL, scope: GitIdentityScope) async throws -> GitIdentity {
        let name = try await configValue("user.name", in: repo, scope: scope)
        let email = try await configValue("user.email", in: repo, scope: scope)
        return GitIdentity(name: name, email: email)
    }

    /// Writes the two fields separately using Git's own configuration locks.
    /// Callers coordinate repository access; an interrupted save is not rolled
    /// back because another Git process may have edited the configuration.
    public func setConfiguredIdentity(name: String, email: String, scope: GitIdentityScope, in repo: URL) async throws {
        let name = try validatedIdentityField(name, label: "Name", isEmail: false)
        let email = try validatedIdentityField(email, label: "Email", isEmail: true)
        try Task.checkCancellation()
        do {
            for (key, value) in [("user.name", name), ("user.email", email)] {
                let result = try await run(["config", identityScopeOption(scope), "--replace-all", key, value], in: repo)
                guard !result.outputTruncated else {
                    throw GitError(command: "git config", exitCode: result.exitCode,
                                   stderr: "Git configuration output exceeded its limit.\n" + result.stderr)
                }
            }
        } catch {
            let warning = "Commit author defaults may be partially saved. Reload both values before trying again."
            if let gitError = error as? GitError {
                throw GitError(command: gitError.command, exitCode: gitError.exitCode,
                               stderr: warning + "\n\n" + gitError.stderr)
            }
            let detail = error is CancellationError ? "Saving commit author defaults was cancelled." : error.localizedDescription
            throw GitError(command: "git config", exitCode: -1, stderr: warning + "\n\n" + detail)
        }
    }

    private func validatedIdentityField(_ raw: String, label: String, isEmail: Bool) throws -> String {
        guard !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) }),
              !raw.contains("<"), !raw.contains(">") else {
            throw GitError(command: "git config", exitCode: -1,
                           stderr: "\(label) cannot contain control characters, line breaks, or angle brackets.")
        }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw GitError(command: "git config", exitCode: -1, stderr: "\(label) is required.")
        }
        guard !isEmail || !value.contains(where: \.isWhitespace) else {
            throw GitError(command: "git config", exitCode: -1, stderr: "Email cannot contain whitespace.")
        }
        return value
    }

    private func identityScopeOption(_ scope: GitIdentityScope) -> String {
        scope == .repository ? "--local" : "--global"
    }

    /// `git config <key>` -> trimmed value, nil when unset (exit 1) or set
    /// to an empty/whitespace-only string.
    private func configValue(_ key: String, in repo: URL, scope: GitIdentityScope? = nil) async throws -> String? {
        let options = scope.map { [identityScopeOption($0), "--includes", "--get"] } ?? []
        let result = try await run(["config"] + options + [key], in: repo, toleratedExitCodes: [1])
        if result.outputTruncated {
            throw GitError(command: "git config", exitCode: result.exitCode, stderr: "Git configuration output exceeded its limit.")
        }
        guard let text = String(data: result.stdout, encoding: .utf8) else {
            throw GitError(command: "git config", exitCode: -1,
                           stderr: "Git configuration contains text outside UTF-8. Edit it with Git or a text editor before saving an identity.")
        }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    // MARK: - Undo snapshots
    //
    // One-level undo for the two operations where RepoDeck itself rewrites
    // local history: `pull()` and the auto-rebase branch of
    // `pushWithAutoRebase`. A snapshot is a git ref, not in-memory state, so
    // it survives `git gc`. Every worktree/branch pair has its own namespace;
    // snapshots from another worktree or branch are never pruned or restored.

    /// Full OID of HEAD. `git rev-parse HEAD`.
    public func headOID(in repo: URL) async throws -> String {
        let result = try await run(["rev-parse", "HEAD"], in: repo)
        return String(decoding: result.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Keeps one undo reference per worktree and branch. A new snapshot is
    /// written before pruning older ones, so a failed write retains recovery.
    public func writeUndoSnapshot(in repo: URL) async throws -> UndoSnapshot {
        let context = try await undoContext(in: repo)
        let oid = try await headOID(in: repo)
        let namespace = Self.undoNamespace(gitDir: context.gitDir, branch: context.branch)
        let refName = "\(namespace)/\(UUID().uuidString.lowercased())"
        try await runVoid(["update-ref", refName, oid], in: repo)
        try await pruneUndoSnapshots(namespace: namespace, keeping: refName, in: repo)
        return UndoSnapshot(refName: refName, oid: oid, branchRef: context.branch, worktreeGitDir: context.gitDir)
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
        let context = try await undoContext(in: repo)
        let currentHead = try await headOID(in: repo)
        guard snapshot.worktreeGitDir == context.gitDir,
              snapshot.branchRef == context.branch,
              snapshot.refName.hasPrefix(Self.undoNamespace(gitDir: context.gitDir, branch: context.branch) + "/"),
              currentHead == expectedHead else {
            throw GitError(
                command: "git reset --keep",
                exitCode: -1,
                stderr: "repository has moved on since the snapshot"
            )
        }
        // A superseded snapshot must not be revived from a stale UI record.
        let recorded = try await run(["rev-parse", "--verify", "--quiet", snapshot.refName], in: repo, toleratedExitCodes: [1])
        guard recorded.exitCode == 0, Self.outputLine(recorded.stdout) == snapshot.oid else {
            throw GitError(command: "git reset --keep", exitCode: -1, stderr: "repository has moved on since the snapshot")
        }
        try await runVoid(["reset", "--keep", snapshot.oid], in: repo)
        await discardUndoSnapshot(snapshot, in: repo)
    }

    /// Deletes the snapshot ref — best effort, used both after a successful
    /// restore and when a newer operation supersedes an unused snapshot.
    /// `git update-ref -d <refName>`; any failure (e.g. the ref is already
    /// gone) is ignored.
    public func discardUndoSnapshot(_ snapshot: UndoSnapshot, in repo: URL) async {
        guard snapshot.refName.hasPrefix("refs/repodeck/undo/") else { return }
        try? await runVoid(["update-ref", "-d", snapshot.refName, snapshot.oid], in: repo)
    }

    /// Prunes only the current worktree/branch's superseded snapshots.
    private func pruneUndoSnapshots(namespace: String, keeping refName: String, in repo: URL) async throws {
        let result = try await run(["for-each-ref", "--format=%(refname)", namespace + "/"], in: repo)
        let refs = String(decoding: result.stdout, as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
        for ref in refs where ref != refName {
            try? await runVoid(["update-ref", "-d", ref], in: repo)
        }
    }

    private func undoContext(in repo: URL) async throws -> (gitDir: String, branch: String?) {
        let directory = try await run(["rev-parse", "--absolute-git-dir"], in: repo)
        let branch = try await run(["symbolic-ref", "--quiet", "HEAD"], in: repo, toleratedExitCodes: [1])
        let gitDir = URL(fileURLWithPath: Self.outputLine(directory.stdout)).resolvingSymlinksInPath().standardizedFileURL.path
        return (gitDir, branch.exitCode == 0 ? Self.outputLine(branch.stdout) : nil)
    }

    private static func undoNamespace(gitDir: String, branch: String?) -> String {
        let identity = gitDir + "\u{0}" + (branch ?? "(detached)")
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return "refs/repodeck/undo/\(digest)"
    }

    private static func outputLine(_ data: Data) -> String {
        var result = String(decoding: data, as: UTF8.self)
        if result.hasSuffix("\n") { result.removeLast() }
        return result
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

    /// NUL-separated records with immutable object IDs and current reflog indices.
    private static let stashFormat = "%gd%x1f%H%x1f%gs%x1f%cI"

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
        // than 0. Return the flagged result for callers to handle explicitly:
        // status can preserve partial records; diffs and identity reads reject
        // truncated output rather than interpreting it as complete data.
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
