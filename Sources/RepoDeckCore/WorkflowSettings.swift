import Foundation
import RepoDeckKit

public struct WorkflowSettings: Codable, Equatable, Sendable {
    public var gitPath: String = GitDefaults.gitPath
    public var ghPath: String = ""
    public var glabPath: String = ""
    public var editorApplicationPath: String = ""
    public var terminalApplicationPath: String = "/System/Applications/Utilities/Terminal.app"
    public init() {}

    public func validated() throws -> Self {
        for (name, path) in [("Git", gitPath), ("GitHub CLI", ghPath), ("GitLab CLI", glabPath)] where !path.isEmpty {
            guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else {
                throw GitError(command: "Settings", exitCode: -1, stderr: "\(name) must point to an executable file using an absolute path.")
            }
        }
        guard !gitPath.isEmpty else { throw GitError(command: "Settings", exitCode: -1, stderr: "Choose a Git executable.") }
        for path in [editorApplicationPath, terminalApplicationPath] where !path.isEmpty {
            guard path.hasPrefix("/"), path.hasSuffix(".app"), FileManager.default.fileExists(atPath: path) else {
                throw GitError(command: "Settings", exitCode: -1, stderr: "Choose an installed macOS application.")
            }
        }
        return self
    }
}

public enum RepositoryAttentionFilter: String, CaseIterable, Sendable {
    case all = "All repositories"
    case changes = "Uncommitted changes"
    case conflicts = "Conflicts"
    case ahead = "Needs push"
    case behind = "Needs pull"
    case errors = "Errors"
}
