import Foundation
import Testing
@testable import RepoDeckKit

/// Fixtures below are trimmed real `gh pr list --json
/// number,title,isDraft,url,reviewDecision,statusCheckRollup` output,
/// captured live against nodejs/node, rails/rails, and cli/cli (2026-07-14,
/// gh 2.89.0) — not hand-guessed shapes. Two real-world quirks these
/// fixtures exist to pin down:
/// - a `CheckRun` still in progress reports `"conclusion":""` (empty
///   string), not `null` and not an absent key;
/// - a PR with no review decision reports `"reviewDecision":""` (empty
///   string), not `null`.
private func wrap(_ prJSON: String) -> Data {
    Data("[\(prJSON)]".utf8)
}

@Test func checkRunCompletedSuccessCollapsesToPassing() throws {
    // nodejs/node PR #64482, "build-tarball" job.
    let data = wrap(#"""
    {
        "number": 64482, "title": "src: tidy up buffer handling", "isDraft": false,
        "url": "https://github.com/nodejs/node/pull/64482", "reviewDecision": "REVIEW_REQUIRED",
        "statusCheckRollup": [
            {"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS","name":"build-tarball","workflowName":"Build from tarball","startedAt":"2026-07-14T22:15:06Z","completedAt":"2026-07-14T22:19:16Z","detailsUrl":"https://github.com/nodejs/node/actions/runs/29372367040/job/87218325087"}
        ]
    }
    """#)

    let info = try GhJSONParser.parse(data)

    #expect(info?.checks == .passing)
}

@Test func checkRunCompletedFailureCollapsesToFailing() throws {
    // nodejs/node PR #64507, "test-macOS" job.
    let data = wrap(#"""
    {
        "number": 64507, "title": "test: fix macOS flake", "isDraft": false,
        "url": "https://github.com/nodejs/node/pull/64507", "reviewDecision": "REVIEW_REQUIRED",
        "statusCheckRollup": [
            {"__typename":"CheckRun","status":"COMPLETED","conclusion":"FAILURE","name":"test-macOS","workflowName":"Test macOS","startedAt":"2026-07-14T22:15:27Z","completedAt":"2026-07-14T23:03:01Z","detailsUrl":"https://github.com/nodejs/node/actions/runs/29372367020/job/87218387012"}
        ]
    }
    """#)

    let info = try GhJSONParser.parse(data)

    #expect(info?.checks == .failing)
}

@Test func checkRunInProgressWithEmptyStringConclusionCollapsesToPending() throws {
    // nodejs/node PR #64507, "coverage-linux" job — still running. Real gh
    // output reports `"conclusion":""`, not null, while in progress.
    let data = wrap(#"""
    {
        "number": 64507, "title": "test: fix macOS flake", "isDraft": false,
        "url": "https://github.com/nodejs/node/pull/64507", "reviewDecision": "REVIEW_REQUIRED",
        "statusCheckRollup": [
            {"__typename":"CheckRun","status":"IN_PROGRESS","conclusion":"","name":"coverage-linux","workflowName":"Coverage Linux","startedAt":"2026-07-14T22:15:09Z","completedAt":"0001-01-01T00:00:00Z","detailsUrl":"https://github.com/nodejs/node/actions/runs/29372367012/job/87218325019"}
        ]
    }
    """#)

    let info = try GhJSONParser.parse(data)

    #expect(info?.checks == .pending)
}

@Test func checkRunCancelledConclusionCollapsesToFailing() throws {
    // nodejs/node PR #64497, "build-tarball" job — cancelled counts as failing.
    let data = wrap(#"""
    {
        "number": 64497, "title": "doc: update guide", "isDraft": false,
        "url": "https://github.com/nodejs/node/pull/64497", "reviewDecision": "REVIEW_REQUIRED",
        "statusCheckRollup": [
            {"__typename":"CheckRun","status":"COMPLETED","conclusion":"CANCELLED","name":"build-tarball","workflowName":"Build from tarball","startedAt":"2026-07-14T12:35:30Z","completedAt":"2026-07-14T12:36:48Z","detailsUrl":"https://github.com/nodejs/node/actions/runs/29333064259/job/87085470281"}
        ]
    }
    """#)

    let info = try GhJSONParser.parse(data)

    #expect(info?.checks == .failing)
}

@Test func checkRunSkippedConclusionAlongsideSuccessCollapsesToPassing() throws {
    // Real rollups are full of SKIPPED conditional jobs (e.g. cli/cli PR
    // Triaging workflow); SKIPPED must not force pending or failing.
    let data = wrap(#"""
    {
        "number": 13873, "title": "Warn when a token is stored in plain text", "isDraft": false,
        "url": "https://github.com/cli/cli/pull/13873", "reviewDecision": "REVIEW_REQUIRED",
        "statusCheckRollup": [
            {"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS","name":"check-requirements","workflowName":"PR Triaging"},
            {"__typename":"CheckRun","status":"COMPLETED","conclusion":"SKIPPED","name":"close-unmet-requirements","workflowName":"PR Triaging"}
        ]
    }
    """#)

    let info = try GhJSONParser.parse(data)

    #expect(info?.checks == .passing)
}

@Test func checkRunStartupFailureConclusionCollapsesToFailing() throws {
    // GitHub Actions conclusion when a workflow fails to even start (e.g. a
    // runner provisioning error) — CI has NOT passed, must not read green.
    let data = wrap(#"""
    {
        "number": 64510, "title": "ci: bump runner image", "isDraft": false,
        "url": "https://github.com/nodejs/node/pull/64510", "reviewDecision": "REVIEW_REQUIRED",
        "statusCheckRollup": [
            {"__typename":"CheckRun","status":"COMPLETED","conclusion":"STARTUP_FAILURE","name":"build-tarball","workflowName":"Build from tarball","startedAt":"2026-07-14T22:15:06Z","completedAt":"2026-07-14T22:15:07Z","detailsUrl":"https://github.com/nodejs/node/actions/runs/29372367041/job/87218325088"}
        ]
    }
    """#)

    let info = try GhJSONParser.parse(data)

    #expect(info?.checks == .failing)
}

@Test func statusContextExpectedStateCollapsesToPending() throws {
    // Classic Commit-Status-API "EXPECTED" state: the context is required
    // but hasn't reported yet — not yet passed, must not read green.
    let data = wrap(#"""
    {
        "number": 58121, "title": "Add new required status check", "isDraft": false,
        "url": "https://github.com/rails/rails/pull/58121", "reviewDecision": "REVIEW_REQUIRED",
        "statusCheckRollup": [
            {"__typename":"StatusContext","context":"buildkite/rails","state":"EXPECTED","startedAt":"2026-07-14T20:28:16Z","targetUrl":"https://buildkite.com/rails/rails/builds/130977"}
        ]
    }
    """#)

    let info = try GhJSONParser.parse(data)

    #expect(info?.checks == .pending)
}

@Test func statusContextSuccessCollapsesToPassing() throws {
    // rails/rails PR #58120, buildkite status contexts (classic Commit
    // Status API, not Checks).
    let data = wrap(#"""
    {
        "number": 58120, "title": "Fix routing edge-case", "isDraft": false,
        "url": "https://github.com/rails/rails/pull/58120", "reviewDecision": "REVIEW_REQUIRED",
        "statusCheckRollup": [
            {"__typename":"StatusContext","context":"buildkite/rails","state":"SUCCESS","startedAt":"2026-07-14T20:28:16Z","targetUrl":"https://buildkite.com/rails/rails/builds/130976"},
            {"__typename":"StatusContext","context":"buildkite/docs-preview","state":"SUCCESS","startedAt":"2026-07-14T20:25:01Z","targetUrl":"https://buildkite.com/rails/docs-preview/builds/20598"}
        ]
    }
    """#)

    let info = try GhJSONParser.parse(data)

    #expect(info?.checks == .passing)
}

@Test func statusContextFailureCollapsesToFailing() throws {
    // rails/rails PR #58113, buildkite/rails failed.
    let data = wrap(#"""
    {
        "number": 58113, "title": "WIP: refactor query cache", "isDraft": false,
        "url": "https://github.com/rails/rails/pull/58113", "reviewDecision": null,
        "statusCheckRollup": [
            {"__typename":"StatusContext","context":"buildkite/rails","state":"FAILURE","startedAt":"2026-07-14T01:29:42Z","targetUrl":"https://buildkite.com/rails/rails/builds/130944"},
            {"__typename":"StatusContext","context":"buildkite/docs-preview","state":"SUCCESS","startedAt":"2026-07-14T00:31:35Z","targetUrl":"https://buildkite.com/rails/docs-preview/builds/20569"}
        ]
    }
    """#)

    let info = try GhJSONParser.parse(data)

    #expect(info?.checks == .failing)
}

@Test func mixedCheckRunAndStatusContextWithOneFailureCollapsesToFailing() throws {
    // nodejs/node PR #64507 mixes CheckRun (Actions) and StatusContext
    // (Jenkins) entries on the same PR; one StatusContext failure should
    // dominate a passing CheckRun.
    let data = wrap(#"""
    {
        "number": 64507, "title": "test: fix macOS flake", "isDraft": false,
        "url": "https://github.com/nodejs/node/pull/64507", "reviewDecision": "REVIEW_REQUIRED",
        "statusCheckRollup": [
            {"__typename":"StatusContext","context":"node-test-commit","state":"FAILURE","startedAt":"2026-07-14T23:18:30Z","targetUrl":"https://ci.nodejs.org/job/node-test-commit/89479/"},
            {"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS","name":"check-requirements","workflowName":"PR Triaging"}
        ]
    }
    """#)

    let info = try GhJSONParser.parse(data)

    #expect(info?.checks == .failing)
}

@Test func mixedCheckRunAndStatusContextAllPassingCollapsesToPassing() throws {
    let data = wrap(#"""
    {
        "number": 64482, "title": "src: tidy up buffer handling", "isDraft": false,
        "url": "https://github.com/nodejs/node/pull/64482", "reviewDecision": "REVIEW_REQUIRED",
        "statusCheckRollup": [
            {"__typename":"StatusContext","context":"node-test-commit-aix","state":"SUCCESS","startedAt":"2026-07-14T13:16:33Z","targetUrl":"https://ci.nodejs.org/job/node-test-commit-aix/63695/"},
            {"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS","name":"build-tarball","workflowName":"Build from tarball"}
        ]
    }
    """#)

    let info = try GhJSONParser.parse(data)

    #expect(info?.checks == .passing)
}

@Test func emptyRollupCollapsesToNone() throws {
    let data = wrap(#"""
    {
        "number": 1, "title": "No CI configured", "isDraft": false,
        "url": "https://github.com/example/example/pull/1", "reviewDecision": "APPROVED",
        "statusCheckRollup": []
    }
    """#)

    let info = try GhJSONParser.parse(data)

    #expect(info?.checks == CheckRollup.none)
}

@Test func noOpenPRProducesNilFromEmptyTopLevelArray() throws {
    // `gh pr list --head <branch> ...` with no match for the branch prints
    // exactly `[]` — confirmed live.
    let info = try GhJSONParser.parse(Data("[]".utf8))

    #expect(info == nil)
}

@Test func draftPRDecodesIsDraftTrue() throws {
    // nodejs/node PR #64472.
    let data = wrap(#"""
    {
        "number": 64472, "title": "WIP: streaming refactor", "isDraft": true,
        "url": "https://github.com/nodejs/node/pull/64472", "reviewDecision": "REVIEW_REQUIRED",
        "statusCheckRollup": []
    }
    """#)

    let info = try GhJSONParser.parse(data)

    #expect(info?.isDraft == true)
}

@Test func nullReviewDecisionNormalizedToNil() throws {
    let data = wrap(#"""
    {
        "number": 2, "title": "No reviewers requested yet", "isDraft": false,
        "url": "https://github.com/example/example/pull/2", "reviewDecision": null,
        "statusCheckRollup": []
    }
    """#)

    let info = try GhJSONParser.parse(data)

    #expect(info?.reviewDecision == nil)
}

@Test func emptyStringReviewDecisionNormalizedToNil() throws {
    // Real gh quirk (nodejs/node PR #64498): "no review decision" is
    // serialized as an empty string, not JSON null.
    let data = wrap(#"""
    {
        "number": 64498, "title": "fix: typo in comment", "isDraft": false,
        "url": "https://github.com/nodejs/node/pull/64498", "reviewDecision": "",
        "statusCheckRollup": []
    }
    """#)

    let info = try GhJSONParser.parse(data)

    #expect(info?.reviewDecision == nil)
}

@Test func approvedReviewDecisionPassesThroughVerbatim() throws {
    let data = wrap(#"""
    {
        "number": 3, "title": "Ready to merge", "isDraft": false,
        "url": "https://github.com/example/example/pull/3", "reviewDecision": "APPROVED",
        "statusCheckRollup": []
    }
    """#)

    let info = try GhJSONParser.parse(data)

    #expect(info?.reviewDecision == "APPROVED")
}

@Test func decodedFieldsMatchInputForOrdinaryPR() throws {
    let data = wrap(#"""
    {
        "number": 42, "title": "Add widget support", "isDraft": false,
        "url": "https://github.com/example/example/pull/42", "reviewDecision": "CHANGES_REQUESTED",
        "statusCheckRollup": []
    }
    """#)

    let info = try GhJSONParser.parse(data)

    #expect(info?.number == 42)
    #expect(info?.title == "Add widget support")
    #expect(info?.url == "https://github.com/example/example/pull/42")
    #expect(info?.reviewDecision == "CHANGES_REQUESTED")
}

@Test func unknownTopLevelAndCheckFieldsAreTolerated() throws {
    // Real `gh` responses carry many more fields (additions, mergeable,
    // workflowName, detailsUrl, ...) than this app models. Decoding must
    // ignore whatever it doesn't recognize rather than throw.
    let data = wrap(#"""
    {
        "number": 5, "title": "Feature", "isDraft": false, "additions": 120, "mergeable": "MERGEABLE",
        "url": "https://github.com/example/example/pull/5", "reviewDecision": "APPROVED",
        "statusCheckRollup": [
            {"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS","name":"build","workflowName":"CI","detailsUrl":"https://example.com","startedAt":"2026-01-01T00:00:00Z","completedAt":"2026-01-01T00:05:00Z"}
        ]
    }
    """#)

    let info = try GhJSONParser.parse(data)

    #expect(info?.number == 5)
    #expect(info?.checks == .passing)
}

@Test func missingOptionalFieldsDecodeWithDefaults() throws {
    // Defensive: even though the app always requests every field it needs
    // via `--json`, a future gh version dropping a field from its own
    // output must not crash the parse.
    let data = wrap(#"{"number": 7}"#)

    let info = try GhJSONParser.parse(data)

    #expect(info?.number == 7)
    #expect(info?.title == "")
    #expect(info?.isDraft == false)
    #expect(info?.url == "")
    #expect(info?.reviewDecision == nil)
    #expect(info?.checks == CheckRollup.none)
}
