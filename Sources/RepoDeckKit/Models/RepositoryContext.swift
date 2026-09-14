import Foundation

/// Git resolves its own layout; linked worktrees need both private and shared metadata.
public struct RepositoryContext: Sendable, Hashable, Identifiable {
    public let worktreeRoot: URL
    public let gitDir: URL
    public let commonGitDir: URL
    public var id: String { worktreeRoot.path }

    public init(worktreeRoot: URL, gitDir: URL, commonGitDir: URL) {
        self.worktreeRoot = worktreeRoot.resolvingSymlinksInPath().standardizedFileURL
        self.gitDir = gitDir.resolvingSymlinksInPath().standardizedFileURL
        self.commonGitDir = commonGitDir.resolvingSymlinksInPath().standardizedFileURL
    }

    public static func resolve(in repo: URL, gitPath: String = GitDefaults.gitPath) async throws -> Self {
        let args = ["-C", repo.path, "rev-parse", "--path-format=absolute", "--show-toplevel", "--absolute-git-dir", "--git-common-dir"]
        let result = try await ProcessRunner.run(gitPath, arguments: args, maxOutputBytes: 64_000)
        guard result.exitCode == 0, !result.outputTruncated,
              let text = String(data: result.stdout, encoding: .utf8) else {
            throw GitError(command: "git rev-parse", exitCode: result.exitCode, stderr: result.stderr)
        }
        let paths = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard paths.count == 4, paths.last == "", paths.prefix(3).allSatisfy({ $0.hasPrefix("/") }) else {
            throw GitError(command: "git rev-parse", exitCode: -1, stderr: "Unable to resolve repository layout safely.")
        }
        return Self(worktreeRoot: URL(fileURLWithPath: String(paths[0])),
                    gitDir: URL(fileURLWithPath: String(paths[1])),
                    commonGitDir: URL(fileURLWithPath: String(paths[2])))
    }
}

public enum RepositoryOperationState: String, Sendable, Equatable {
    case normal, merge, rebase, cherryPick, revert, unsupported
    public var label: String {
        switch self {
        case .normal: "Ready"
        case .merge: "Merge in progress"
        case .rebase: "Rebase in progress"
        case .cherryPick: "Cherry-pick in progress"
        case .revert: "Revert in progress"
        case .unsupported: "Git operation in progress"
        }
    }
    public static func read(in context: RepositoryContext) -> Self {
        let fm = FileManager.default
        func exists(_ name: String) -> Bool { fm.fileExists(atPath: context.gitDir.appendingPathComponent(name).path) }
        if exists("rebase-merge") || exists("rebase-apply") { return .rebase }
        if exists("MERGE_HEAD") { return .merge }
        if exists("CHERRY_PICK_HEAD") { return .cherryPick }
        if exists("REVERT_HEAD") { return .revert }
        if exists("sequencer") { return .unsupported }
        return .normal
    }

    /// Snapshot the operation's identity and progress before presenting a write.
    /// A new merge/rebase at the same HEAD must not inherit an old confirmation.
    public static func fingerprint(in context: RepositoryContext) -> [String: Data] {
        var values = ["state": Data(read(in: context).rawValue.utf8)]
        let paths = ["MERGE_HEAD", "MERGE_AUTOSTASH", "CHERRY_PICK_HEAD", "REVERT_HEAD",
                     "sequencer/head", "sequencer/todo", "sequencer/abort-safety",
                     "rebase-merge/head-name", "rebase-merge/onto", "rebase-merge/orig-head",
                     "rebase-merge/git-rebase-todo", "rebase-merge/done", "rebase-merge/stopped-sha",
                     "rebase-apply/head-name", "rebase-apply/onto", "rebase-apply/orig-head",
                     "rebase-apply/next", "rebase-apply/last", "rebase-apply/original-commit"]
        for path in paths {
            if let data = try? Data(contentsOf: context.gitDir.appendingPathComponent(path)) { values[path] = data }
        }
        return values
    }
}

public enum OperationResult: Sendable, Equatable {
    case succeeded
    case failed(String)
    case skipped(String)
}
