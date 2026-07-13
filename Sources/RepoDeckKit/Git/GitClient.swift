import Foundation

/// Outcome of `GitClient.pushWithAutoRebase(in:)`: whether the push landed
/// on the first attempt or required a rebase-and-retry.
public enum PushOutcome: Sendable, Equatable {
    case pushed
    case rebasedAndPushed
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
        try await runVoid(["pull"], in: repo)
    }

    /// `git -C <repo> push`
    public func push(in repo: URL) async throws {
        try await runVoid(["push"], in: repo)
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
            try await runVoid(["push"], in: repo)
            return .pushed
        } catch let error as GitError where error.isNonFastForwardPushRejection {
            do {
                try await runVoid(["pull", "--rebase", "--autostash"], in: repo)
            } catch let pullError as GitError {
                try? await runVoid(["rebase", "--abort"], in: repo)
                throw pullError
            }
            try await runVoid(["push"], in: repo)
            return .rebasedAndPushed
        }
    }

    /// `git -C <repo> fetch`
    public func fetch(in repo: URL) async throws {
        try await runVoid(["fetch"], in: repo)
    }

    // MARK: - Private helpers

    /// Pretty-format shared by `log` and `searchLog`, kept in exactly one
    /// place so both stay in lockstep with `LogParser`'s field layout.
    private static let logFormat = "%H%x1f%h%x1f%s%x1f%an%x1f%aI%x1f%D%x1e"

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
    private func run(
        _ arguments: [String],
        in repo: URL,
        environment: [String: String] = [:],
        maxOutputBytes: Int? = nil
    ) async throws -> ProcessResult {
        let fullArguments = ["-C", repo.path] + arguments
        let result = try await ProcessRunner.run(
            gitPath,
            arguments: fullArguments,
            environment: environment,
            maxOutputBytes: maxOutputBytes
        )
        // `ProcessRunner` enforces `maxOutputBytes` by SIGTERM-ing the child,
        // which makes `terminationStatus` a nonzero signal exit (15) rather
        // than 0 — that is expected, not a failure. Only `status` passes
        // `maxOutputBytes`, so this can't mask a real failure of any other
        // command.
        guard result.exitCode == 0 || result.outputTruncated else {
            throw GitError(
                command: commandString(fullArguments),
                exitCode: result.exitCode,
                stderr: result.stderr
            )
        }
        return result
    }

    /// Convenience for commands whose stdout the caller never inspects.
    private func runVoid(_ arguments: [String], in repo: URL) async throws {
        _ = try await run(arguments, in: repo)
    }

    private func commandString(_ arguments: [String]) -> String {
        (["git"] + arguments).joined(separator: " ")
    }
}
