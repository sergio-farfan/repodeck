import Foundation
import Testing
import RepoDeckKit
@testable import RepoDeckCore

private actor ReviewGate {
    var continuations: [CheckedContinuation<PullRequestInfo?, Never>] = []
    func load() async -> PullRequestInfo? {
        await withCheckedContinuation { continuations.append($0) }
    }
    var count: Int { continuations.count }
    func complete(_ index: Int, number: Int) {
        continuations[index].resume(returning: PullRequestInfo(number: number, title: "Review \(number)", isDraft: false,
            url: "https://example.invalid/review/\(number)", reviewDecision: nil, checks: .none))
    }
}

@Suite("Refresh ordering and workspace state")
@MainActor
struct RefreshAndGraphTests {
    @Test func returningFromDetachedHeadReplacesCancelledReviewRefresh() async {
        let gate = ReviewGate()
        let vm = RepoViewModel(repo: Repo(path: URL(fileURLWithPath: "/tmp/review-order")), client: GitClient(),
                               reviewLoader: { _, _, _ in await gate.load() })
        let gh = GhClient(ghPath: "/unused")
        vm.status = RepoStatus(branch: "feature")
        let original = Task { await vm.refreshPRInfo(using: gh) }
        while await gate.count < 1 { await Task.yield() }
        vm.status = RepoStatus(branch: "(detached)")
        await vm.refreshPRInfo(using: gh)
        vm.status = RepoStatus(branch: "feature")
        let replacement = Task { await vm.refreshPRInfo(using: gh) }
        let deadline = ContinuousClock.now + .seconds(2)
        while await gate.count < 2, ContinuousClock.now < deadline { await Task.yield() }
        let count = await gate.count
        #expect(count == 2)
        if count == 2 {
            await gate.complete(1, number: 22)
            await replacement.value
        }
        await gate.complete(0, number: 11)
        await original.value
        await replacement.value
        #expect(vm.prInfo?.number == 22)
    }

    @Test func oldReviewCannotReplaceNewBranchResult() async {
        let gate = ReviewGate()
        let vm = RepoViewModel(repo: Repo(path: URL(fileURLWithPath: "/tmp/review-switch")), client: GitClient(),
                               reviewLoader: { _, _, _ in await gate.load() })
        let gh = GhClient(ghPath: "/unused")
        vm.status = RepoStatus(branch: "old")
        let original = Task { await vm.refreshPRInfo(using: gh) }
        while await gate.count < 1 { await Task.yield() }
        vm.status = RepoStatus(branch: "new")
        let replacement = Task { await vm.refreshPRInfo(using: gh) }
        while await gate.count < 2 { await Task.yield() }
        await gate.complete(1, number: 2)
        await replacement.value
        await gate.complete(0, number: 1)
        await original.value
        #expect(vm.prInfo?.number == 2)
    }

    @Test func queuedMutationCancellationReleasesCapacity() async throws {
        let coordinator = RepositoryMutationCoordinator()
        try await coordinator.acquire("common")
        let waiter = Task { try await coordinator.acquire("common") }
        await Task.yield()
        waiter.cancel()
        do { try await waiter.value; Issue.record("Cancelled waiter acquired capacity") }
        catch is CancellationError {} catch { Issue.record(error) }
        await coordinator.release("common")
        try await coordinator.acquire("common")
        await coordinator.release("common")
    }

    @Test func graphKeepsMergeEdgesAndCollapsesJoinedLanes() {
        func node(_ oid: String, _ parents: [String]) -> GraphCommit {
            GraphCommit(commit: Commit(hash: oid, shortHash: oid, subject: oid, author: "Test", date: Date(timeIntervalSince1970: 0), refs: []), parents: parents)
        }
        let rows = GraphLaneRow.layout([node("merge", ["left", "right"]), node("left", ["base"]), node("right", ["base"]), node("base", [])])
        #expect(rows[0].edges.count == 2)
        #expect(rows[0].width == 2)
        #expect(rows[2].column == 1)
        #expect(rows[2].edges.contains { $0.from == 1 && $0.to == 0 })
        #expect(rows[3].width == 1)
        #expect(rows[3].edges.isEmpty)
    }

    @Test func perWorktreeSelectionsAndDraftsRemainIndependent() {
        let first = RepoViewModel(repo: Repo(path: URL(fileURLWithPath: "/tmp/first")), client: GitClient())
        let second = RepoViewModel(repo: Repo(path: URL(fileURLWithPath: "/tmp/second")), client: GitClient())
        first.commitMessage = "First draft"
        first.workspace.resolution = "First resolution"
        first.workspace.selectedCommit = "abc"
        first.selectedSection = .history
        second.commitMessage = "Second draft"
        second.workspace.resolution = "Second resolution"
        #expect(first.commitMessage == "First draft")
        #expect(first.workspace.resolution == "First resolution")
        #expect(first.workspace.selectedCommit == "abc")
        #expect(first.selectedSection == .history)
    }
}
