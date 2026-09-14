import Foundation

public struct BranchInfo: Identifiable, Hashable, Sendable {
    public let name: String
    public let fullRef: String
    public let oid: String
    public let isCurrent: Bool
    public let isRemote: Bool
    public let upstream: String?
    public let worktreePath: String?
    public var id: String { fullRef }
}

public struct WorktreeInfo: Identifiable, Hashable, Sendable {
    public let path: URL
    public let branch: String?
    public let oid: String?
    public let isMain: Bool
    public let isBare: Bool
    public let isLocked: Bool
    public let isPrunable: Bool
    public var id: String { path.path }
}

public struct GraphCommit: Identifiable, Hashable, Sendable {
    public let commit: Commit
    public let parents: [String]
    public var id: String { commit.hash }
    public var hash: String { commit.hash }
    public init(commit: Commit, parents: [String]) {
        self.commit = commit
        self.parents = parents
    }
}

public struct ConflictDocument: Identifiable, Equatable, Sendable {
    public let path: String
    public let base: String?
    public let current: String?
    public let incoming: String?
    public let workingText: String?
    public let unavailableReason: String?
    public var canEdit: Bool { unavailableReason == nil }
    public var id: String { path }

    // Kept separately from display text: mutation requires this exact snapshot.
    let repositoryPath: String
    let headOID: String
    let indexEntries: Data
    let workingData: Data?
    let workingMode: UInt16?
}
