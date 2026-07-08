import Foundation

public struct Repo: Identifiable, Hashable, Sendable {
    public let path: URL                 // worktree root
    public var id: String { path.path }
    public var name: String { path.lastPathComponent }

    public init(path: URL) {
        self.path = path
    }
}
