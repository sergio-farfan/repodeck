import Foundation

/// Which axis of a commit `GitClient.searchLog` matches `HistorySearchQuery.text`
/// against.
public enum HistorySearchField: String, CaseIterable, Sendable {
    case message
    case author
    case path
    case content
}

/// A single history search: free text plus the axis to match it against.
/// `GitClient.searchLog` treats whitespace-only `text` as "no filter" and
/// returns the full recent log, same as `GitClient.log`.
public struct HistorySearchQuery: Sendable, Equatable {
    public var text: String
    public var field: HistorySearchField

    public init(text: String, field: HistorySearchField) {
        self.text = text
        self.field = field
    }
}
