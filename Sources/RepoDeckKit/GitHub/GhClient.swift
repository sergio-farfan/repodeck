import Foundation

/// Thrown by `GhClient` when the `gh` subprocess itself fails (non-zero
/// exit, or the timeout watchdog fired) — as opposed to "no open PR", which
/// is a normal `nil` result, not an error. Callers (see
/// `RepoViewModel.refreshPRInfo`) treat this the same as "no PR": a
/// read-only, optional integration never surfaces its own failures as an
/// error banner.
public struct GhError: Error, LocalizedError, Sendable {
    public let command: String
    public let exitCode: Int32
    public let stderr: String

    public var errorDescription: String? {
        stderr.isEmpty ? "gh exited with \(exitCode)" : stderr
    }

    public init(command: String, exitCode: Int32, stderr: String) {
        self.command = command
        self.exitCode = exitCode
        self.stderr = stderr
    }
}

/// Read-only façade over the `gh` CLI for PR + CI status — the app's first
/// non-git subprocess. Deliberately does not go through `GitClient.run`
/// (that hardcodes the git binary and its `-C <repo>` convention); `gh` has
/// no `-C` flag, so every call here passes `repo` as `workingDirectory`
/// straight to `ProcessRunner.run` instead.
///
/// Every entry point is optional-by-construction: `discover()` returns nil
/// when gh isn't installed, `isAuthenticated()` returns false rather than
/// throwing, and `pullRequest(forBranch:in:)` returns nil for "no open PR".
/// The app layer (`AppModel`/`RepoViewModel`) is what turns "nil/false/
/// thrown" into "show nothing" — this type just reports what happened.
public struct GhClient: Sendable {
    public let ghPath: String

    /// Locations `discover()` checks, in order — the same three paths
    /// `GitDefaults` would need to cover Homebrew (Apple silicon and
    /// Intel) and a manual install.
    public static let defaultCandidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]

    /// Environment forced on every `gh` invocation: never prompt (there is
    /// no interactive terminal to prompt on), never nag about a CLI update.
    private static let environment = ["GH_PROMPT_DISABLED": "1", "GH_NO_UPDATE_NOTIFIER": "1"]

    private static let callTimeout: Duration = .seconds(30)

    public init(ghPath: String) {
        self.ghPath = ghPath
    }

    /// First candidate that is an executable file; nil if none (gh not
    /// installed anywhere this app knows to look).
    public static func discover(candidates: [String] = defaultCandidates) -> GhClient? {
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return GhClient(ghPath: candidate)
        }
        return nil
    }

    /// `gh auth status` — exit 0 means authenticated to at least one host.
    /// Meant to run once per launch; the caller (`AppModel`) caches the
    /// resolved bool rather than calling this before every PR refresh.
    public func isAuthenticated() async -> Bool {
        do {
            let result = try await ProcessRunner.run(
                ghPath,
                arguments: ["auth", "status"],
                environment: Self.environment,
                priority: .background,
                timeout: Self.callTimeout
            )
            return !result.timedOut && result.exitCode == 0
        } catch {
            return false
        }
    }

    /// `gh pr list --head <branch> --state open --limit 1 --json number,
    /// title,isDraft,url,reviewDecision,statusCheckRollup`, run in `repo`
    /// (gh has no `-C`, so this is `workingDirectory`, not an argument).
    /// Returns nil when there is no open PR for `branch`. Throws `GhError`
    /// on a non-zero exit or timeout (auth expired, network down, ...) —
    /// callers are expected to catch this and treat it like "no PR", never
    /// surface it as a user-facing error.
    public func pullRequest(forBranch branch: String, in repo: URL) async throws -> PullRequestInfo? {
        let arguments = [
            "pr", "list",
            "--head", branch,
            "--state", "open",
            "--limit", "1",
            "--json", "number,title,isDraft,url,reviewDecision,statusCheckRollup",
        ]
        let result = try await ProcessRunner.run(
            ghPath,
            arguments: arguments,
            workingDirectory: repo,
            environment: Self.environment,
            priority: .background,
            timeout: Self.callTimeout
        )
        if result.timedOut {
            throw GhError(
                command: commandString(arguments),
                exitCode: result.exitCode,
                stderr: "timed out after \(Self.callTimeout.components.seconds)s"
            )
        }
        guard result.exitCode == 0 else {
            throw GhError(command: commandString(arguments), exitCode: result.exitCode, stderr: result.stderr)
        }
        return try GhJSONParser.parse(result.stdout)
    }

    private func commandString(_ arguments: [String]) -> String {
        (["gh"] + arguments).joined(separator: " ")
    }
}
