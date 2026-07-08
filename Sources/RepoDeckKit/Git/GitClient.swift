import Foundation

/// Stateless façade over the git CLI: every view model calls into `GitClient`
/// rather than shelling out directly. Composes `ProcessRunner` (subprocess
/// execution), `PorcelainParser` (status), and `LogParser` (log) into typed
/// git operations. No `Process`/argv details leak past this type.
public struct GitClient: Sendable {
    public var gitPath: String

    public init(gitPath: String = GitDefaults.gitPath) {
        self.gitPath = gitPath
    }

    /// `git -C <repo> status --porcelain=v2 --branch --untracked-files=all -z`
    ///
    /// Runs with `GIT_OPTIONAL_LOCKS=0` (never blocks on another git process
    /// holding the index lock) and a 4 MB output cap; a truncated read is
    /// passed through to `PorcelainParser` rather than treated as failure.
    public func status(in repo: URL) async throws -> RepoStatus {
        let result = try await run(
            ["status", "--porcelain=v2", "--branch", "--untracked-files=all", "-z"],
            in: repo,
            environment: ["GIT_OPTIONAL_LOCKS": "0"],
            maxOutputBytes: 4_000_000
        )
        return PorcelainParser.parse(result.stdout, truncated: result.outputTruncated)
    }

    /// `git -C <repo> log -n <limit> --pretty=format:%H%x1f%h%x1f%s%x1f%an%x1f%aI%x1f%D%x1e`
    ///
    /// Special case: a brand-new repo with no commits yet exits 128 with
    /// stderr containing "does not have any commits" — that is not an error
    /// condition for us, it just means an empty history.
    public func log(in repo: URL, limit: Int = 100) async throws -> [Commit] {
        let format = "%H%x1f%h%x1f%s%x1f%an%x1f%aI%x1f%D%x1e"
        do {
            let result = try await run(["log", "-n", "\(limit)", "--pretty=format:\(format)"], in: repo)
            return LogParser.parse(String(decoding: result.stdout, as: UTF8.self))
        } catch let error as GitError {
            if error.exitCode == 128, error.stderr.contains("does not have any commits") {
                return []
            }
            throw error
        }
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

    /// `git -C <repo> fetch`
    public func fetch(in repo: URL) async throws {
        try await runVoid(["fetch"], in: repo)
    }

    // MARK: - Private helpers

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
        guard result.exitCode == 0 else {
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
