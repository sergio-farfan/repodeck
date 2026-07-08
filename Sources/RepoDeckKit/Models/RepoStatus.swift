import Foundation

public struct RepoStatus: Equatable, Sendable {
    public var branch: String?           // from "# branch.head"; "(detached)" kept verbatim
    public var oid: String?              // "(initial)" for unborn branch
    public var upstream: String?         // nil = no upstream configured
    public var ahead: Int?               // nil when no upstream ("# branch.ab" absent)
    public var behind: Int?
    public var changes: [FileChange]
    public var didHitLimit: Bool         // true when status output was truncated (huge repo)

    public var dirtyCount: Int { changes.count }

    // memberwise public init with default values: nils, [], false
    public init(
        branch: String? = nil,
        oid: String? = nil,
        upstream: String? = nil,
        ahead: Int? = nil,
        behind: Int? = nil,
        changes: [FileChange] = [],
        didHitLimit: Bool = false
    ) {
        self.branch = branch
        self.oid = oid
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.changes = changes
        self.didHitLimit = didHitLimit
    }
}

public enum ChangeArea: Sendable, Hashable {
    case staged
    case unstaged
    case untracked
    case unmerged
}

public struct FileChange: Identifiable, Hashable, Sendable {
    public let path: String              // repo-relative
    public let originalPath: String?     // renames/copies only
    public let area: ChangeArea
    public let statusLetter: String      // "M","A","D","R","C","T"; "U" untracked; "UU"/"AA"… unmerged

    public var id: String { "\(area)-\(path)" }

    public init(path: String, originalPath: String? = nil, area: ChangeArea, statusLetter: String) {
        self.path = path
        self.originalPath = originalPath
        self.area = area
        self.statusLetter = statusLetter
    }
}
