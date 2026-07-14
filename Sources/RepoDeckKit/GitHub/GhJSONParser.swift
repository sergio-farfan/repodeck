import Foundation

/// Parses the JSON array produced by
/// `gh pr list --json number,title,isDraft,url,reviewDecision,statusCheckRollup`
/// into a `PullRequestInfo`. Pure function: no `Process`, no I/O — mirrors
/// `LogParser`'s role for `git log`, but over JSON instead of a delimited
/// text format.
public enum GhJSONParser {
    /// Decodes `gh pr list --json ...` output. `gh pr list` always returns a
    /// JSON array, even for a single PR; an empty array (no open PR matched
    /// the query) decodes to `nil` rather than throwing. Only the first
    /// element is used — callers pass `--limit 1`.
    public static func parse(_ data: Data) throws -> PullRequestInfo? {
        let items = try JSONDecoder().decode([RawPullRequest].self, from: data)
        return items.first.map(\.asPullRequestInfo)
    }

    /// Collapses every entry in a `statusCheckRollup` array into one
    /// `CheckRollup`, in this precedence order: any failing entry wins over
    /// any pending entry, which wins over an all-successful rollup; an empty
    /// array (no checks configured for the PR at all) is `.none`, distinct
    /// from "checks configured and all passing".
    static func collapse(_ checks: [RawCheck]) -> CheckRollup {
        guard !checks.isEmpty else { return .none }
        if checks.contains(where: \.isFailing) { return .failing }
        if checks.contains(where: \.isPending) { return .pending }
        return .passing
    }

    /// Wire shape of one element of the top-level `gh pr list --json ...`
    /// array. Every field is decoded via `decodeIfPresent` with a fallback
    /// default so a future `gh` version dropping or renaming a field never
    /// throws — a missing/unrecognized field just degrades to "unknown",
    /// never blocks the whole parse.
    struct RawPullRequest: Decodable {
        let number: Int
        let title: String
        let isDraft: Bool
        let url: String
        /// Normalized so both a missing key, an explicit JSON `null`, AND
        /// gh's real "no decision" empty-string quirk all become `nil`.
        let reviewDecision: String?
        let statusCheckRollup: [RawCheck]

        enum CodingKeys: String, CodingKey {
            case number, title, isDraft, url, reviewDecision, statusCheckRollup
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            number = try container.decodeIfPresent(Int.self, forKey: .number) ?? 0
            title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
            isDraft = try container.decodeIfPresent(Bool.self, forKey: .isDraft) ?? false
            url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
            let rawReviewDecision = try container.decodeIfPresent(String.self, forKey: .reviewDecision)
            reviewDecision = (rawReviewDecision?.isEmpty ?? true) ? nil : rawReviewDecision
            statusCheckRollup = try container.decodeIfPresent([RawCheck].self, forKey: .statusCheckRollup) ?? []
        }

        var asPullRequestInfo: PullRequestInfo {
            PullRequestInfo(
                number: number,
                title: title,
                isDraft: isDraft,
                url: url,
                reviewDecision: reviewDecision,
                checks: GhJSONParser.collapse(statusCheckRollup)
            )
        }
    }

    /// Wire shape of one `statusCheckRollup` entry. gh's GraphQL-backed
    /// rollup mixes two unrelated shapes on the same array depending on how
    /// the PR's CI reports status:
    /// - a GitHub Actions (or App) **CheckRun**: `status` (QUEUED/
    ///   IN_PROGRESS/COMPLETED/...) + `conclusion` (SUCCESS/FAILURE/
    ///   CANCELLED/TIMED_OUT/ACTION_REQUIRED/SKIPPED/...; empty string, not
    ///   null, while `status` isn't yet COMPLETED);
    /// - a classic Commit-Status-API **StatusContext** (Jenkins, Buildkite,
    ///   etc.): `state` (SUCCESS/FAILURE/ERROR/PENDING/EXPECTED) and no
    ///   `conclusion` field at all.
    ///
    /// Both shapes are decoded into the same struct tolerantly — whichever
    /// fields aren't present for a given entry's actual shape just decode to
    /// `nil` — rather than modeling them as two distinct types, since the
    /// only thing this app does with an entry is classify it via
    /// `isFailing`/`isPending`.
    struct RawCheck: Decodable {
        /// CheckRun only.
        let status: String?
        /// CheckRun only; normalized so gh's empty-string "not completed
        /// yet" value becomes `nil`, matching "no conclusion" semantics.
        let conclusion: String?
        /// StatusContext only.
        let state: String?

        enum CodingKeys: String, CodingKey { case status, conclusion, state }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            status = try container.decodeIfPresent(String.self, forKey: .status)
            let rawConclusion = try container.decodeIfPresent(String.self, forKey: .conclusion)
            conclusion = (rawConclusion?.isEmpty ?? true) ? nil : rawConclusion
            state = try container.decodeIfPresent(String.self, forKey: .state)
        }

        var isFailing: Bool {
            if let conclusion, Self.failingConclusions.contains(conclusion) { return true }
            if let state, Self.failingStates.contains(state) { return true }
            return false
        }

        var isPending: Bool {
            if let status, Self.pendingStatusOrState.contains(status) { return true }
            if let state, Self.pendingStatusOrState.contains(state) { return true }
            // A CheckRun (identified by having a `status` at all) with no
            // conclusion yet is still running, whatever unrecognized
            // `status` value it reports — StatusContext entries have no
            // `status` field at all, so this never misfires on those.
            if status != nil, conclusion == nil { return true }
            return false
        }

        private static let failingConclusions: Set<String> = ["FAILURE", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED"]
        private static let failingStates: Set<String> = ["ERROR", "FAILURE"]
        private static let pendingStatusOrState: Set<String> = ["PENDING", "QUEUED", "IN_PROGRESS"]
    }
}
