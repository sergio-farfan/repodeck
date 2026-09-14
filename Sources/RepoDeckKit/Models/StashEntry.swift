import Foundation

/// A single `git stash` entry: the reflog subject (verbatim) plus the
/// committer date. The object ID is stable when new stashes shift reflog indices.
public struct StashEntry: Identifiable, Hashable, Sendable {
    public let index: Int          // stash@{index}; also id
    public let subject: String     // %gs verbatim, e.g. "WIP on main: 1a2b3c msg"
    public let date: Date?         // %cI parsed ISO8601; nil if unparseable
    public let oid: String?

    public var id: String { oid ?? "legacy-stash-\(index)" }

    public init(index: Int, subject: String, date: Date?, oid: String? = nil) {
        self.index = index
        self.subject = subject
        self.date = date
        self.oid = oid
    }
}
