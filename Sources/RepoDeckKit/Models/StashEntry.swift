import Foundation

/// A single `git stash` entry: the reflog subject (verbatim) plus the
/// committer date it was created, keyed by its `stash@{index}` position.
public struct StashEntry: Identifiable, Hashable, Sendable {
    public let index: Int          // stash@{index}; also id
    public let subject: String     // %gs verbatim, e.g. "WIP on main: 1a2b3c msg"
    public let date: Date?         // %cI parsed ISO8601; nil if unparseable

    public var id: Int { index }

    public init(index: Int, subject: String, date: Date?) {
        self.index = index
        self.subject = subject
        self.date = date
    }
}
