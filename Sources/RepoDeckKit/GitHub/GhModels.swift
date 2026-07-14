import Foundation

/// Read-only snapshot of the current branch's open PR and its CI rollup, as
/// returned by
/// `gh pr list --json number,title,isDraft,url,reviewDecision,statusCheckRollup`.
/// Produced only by `GhJSONParser.parse` — see that type for how
/// `statusCheckRollup` collapses into `checks`.
public struct PullRequestInfo: Sendable, Equatable {
    public let number: Int
    public let title: String
    public let isDraft: Bool
    public let url: String
    /// "APPROVED" / "CHANGES_REQUESTED" / "REVIEW_REQUIRED" / nil. gh
    /// reports "no review decision" as an empty string, not JSON `null` —
    /// `GhJSONParser` normalizes both to `nil` here.
    public let reviewDecision: String?
    public let checks: CheckRollup

    public init(number: Int, title: String, isDraft: Bool, url: String, reviewDecision: String?, checks: CheckRollup) {
        self.number = number
        self.title = title
        self.isDraft = isDraft
        self.url = url
        self.reviewDecision = reviewDecision
        self.checks = checks
    }
}

/// Collapsed CI status across every entry in a PR's `statusCheckRollup`.
/// See `GhJSONParser.collapse(_:)` for the precedence rules: failing beats
/// pending beats passing; an empty rollup (no checks configured) is
/// `.none`.
public enum CheckRollup: String, Sendable, Equatable {
    case none
    case pending
    case passing
    case failing
}
