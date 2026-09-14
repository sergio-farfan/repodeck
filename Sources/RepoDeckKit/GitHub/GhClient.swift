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

    /// Honor the user's PATH before the usual package-manager locations.
    public static var defaultCandidates: [String] {
        (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("gh").path }
            + ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
    }

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

    /// Active account login via `gh auth status` (local — works offline).
    /// nil when not authenticated or the output format is unrecognized.
    /// Same never-throw posture as `isAuthenticated()`: a missing login is
    /// "show nothing", never an error. stdout and stderr are concatenated
    /// before parsing because older gh versions wrote the status report to
    /// stderr; newer ones write it to stdout.
    public func activeAccountLogin() async -> String? {
        do {
            let result = try await ProcessRunner.run(
                ghPath,
                arguments: ["auth", "status"],
                environment: Self.environment,
                priority: .background,
                timeout: Self.callTimeout
            )
            guard !result.timedOut, result.exitCode == 0 else { return nil }
            let output = String(decoding: result.stdout, as: UTF8.self) + "\n" + result.stderr
            return GhAuthStatusParser.activeLogin(from: output)
        } catch {
            return nil
        }
    }

    /// Compatibility badge API. Resolve the branch's source remote and include
    /// source repository identity, since unrelated forks can use the same branch.
    /// The Reviews workspace uses HostingClient directly for explicit remote choice.
    public func pullRequest(forBranch branch: String, in repo: URL, gitPath: String = GitDefaults.gitPath) async throws -> PullRequestInfo? {
        let remotes = try await HostingClient.remotes(in: repo, gitPath: gitPath)
        guard !remotes.isEmpty else { return nil }
        func config(_ key: String) async throws -> String? {
            let value = try await ProcessRunner.run(gitPath, arguments: ["-C", repo.path, "config", "--get", key], timeout: .seconds(10))
            guard value.exitCode == 0 else { return nil }
            let text = String(decoding: value.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        let pushRemote = try await config("branch.\(branch).pushRemote")
        let defaultPushRemote = try await config("remote.pushDefault")
        let trackingRemote = try await config("branch.\(branch).remote")
        let sourceName = pushRemote ?? defaultPushRemote ?? trackingRemote ?? (remotes.contains { $0.name == "origin" } ? "origin" : remotes.count == 1 ? remotes[0].name : "")
        guard let remote = remotes.first(where: { $0.name == sourceName }),
              let source = HostingRepository.parse(remote: remote.url, name: remote.name, provider: .github),
              source.host != "gitlab.com" else { return nil }
        let targetRemote = remotes.first { $0.name == "upstream" } ?? remote
        guard let target = HostingRepository.parse(remote: targetRemote.url, name: targetRemote.name, provider: .github),
              target.host == source.host else { return nil }
        let api = HostingClient(repository: target, cliPath: ghPath, workingDirectory: repo)
        let matches = try await api.matching(source: source, branch: branch)
        guard matches.count == 1, let request = matches.first else { return nil }
        let detail = try await api.detail(number: request.number)
        let states = detail.checks.map { $0.status.lowercased() }
        let rollup: CheckRollup
        if states.isEmpty { rollup = .none }
        else if states.contains(where: { ["failure", "failed", "error", "cancelled", "timed_out", "action_required"].contains($0) }) { rollup = .failing }
        else if states.allSatisfy({ ["success", "passed", "skipped", "neutral"].contains($0) }) { rollup = .passing }
        else { rollup = .pending }
        return PullRequestInfo(number: request.number, title: request.title, isDraft: request.isDraft,
            url: request.url.absoluteString, reviewDecision: nil, checks: rollup)
    }

    private func commandString(_ arguments: [String]) -> String {
        (["gh"] + arguments).joined(separator: " ")
    }
}
