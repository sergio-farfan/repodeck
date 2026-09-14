import Foundation
import Testing
import RepoDeckKit
@testable import RepoDeckCore

private actor ReviewSessionCLI {
    private var calls: [HostingCommand] = []
    private var pauseList = false
    private var pauseUser = false
    private var continuation: CheckedContinuation<Void, Never>?
    var isPaused: Bool { continuation != nil }
    func pauseNextList() { pauseList = true }
    func pauseNextUser() { pauseUser = true }
    func release() { continuation?.resume(); continuation = nil }
    func snapshot() -> [HostingCommand] { calls }
    func run(_ command: HostingCommand) async -> ProcessResult {
        calls.append(command)
        let endpoint = command.arguments[5]
        if (pauseList && endpoint.contains("/pulls?")) || (pauseUser && endpoint == "user") {
            pauseList = false; pauseUser = false
            await withCheckedContinuation { continuation = $0 }
        }
        let json = endpoint == "user" ? #"{"login":"tester"}"# : "[]"
        return ProcessResult(exitCode: 0, stdout: Data(json.utf8), stderr: "", outputTruncated: false)
    }
}

@MainActor
private final class ReviewSessionFixture {
    let root: URL
    let preferences: UserDefaults
    let preferenceName = "RepoDeckReviewSessionTests-\(UUID())"
    let fake = ReviewSessionCLI()
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ReviewSession-\(UUID())")
        preferences = UserDefaults(suiteName: preferenceName)!
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func cleanUp() {
        preferences.removePersistentDomain(forName: preferenceName)
        try? FileManager.default.removeItem(at: root)
    }
    func git(_ arguments: [String]) async throws {
        let result = try await ProcessRunner.run(GitDefaults.gitPath,
            arguments: ["-C", root.path, "-c", "init.templateDir=", "-c", "core.hooksPath=/dev/null"] + arguments,
            environment: ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_TERMINAL_PROMPT": "0"])
        guard result.exitCode == 0 else { throw GitError(command: "fixture git", exitCode: result.exitCode, stderr: result.stderr) }
    }
    func store() async throws -> ReviewsStore {
        try await git(["init", "-b", "main"])
        try await git(["remote", "add", "origin", "https://github.com/acme/first.git"])
        let fake = fake
        return ReviewsStore(repoURL: root, gitPath: GitDefaults.gitPath, ghPath: "/fake/original-gh", glabPath: nil,
            preferences: preferences, runner: { await fake.run($0) })
    }
}

@Suite("Hosting review sessions") @MainActor
struct ReviewsStoreTests {
    @Test func reconnectDiscoversChangedRemotesAndRestoresOnlyTheirOwnDrafts() async throws {
        let fixture = try ReviewSessionFixture()
        defer { fixture.cleanUp() }
        let store = try await fixture.store()
        await store.connect()
        store.draftTitle = "First destination"
        store.draftBody = "First description"
        store.reviewBody = "Unsent first review"
        store.sourceBranch = "feature"; store.targetBranch = "main"
        let firstPreview = try #require(store.createPreview())
        store.selected = 7
        try await fixture.git(["remote", "set-url", "origin", "https://github.com/acme/second.git"])
        await store.connect()
        #expect(store.client?.repository.path == "acme/second")
        #expect(store.selected == nil)
        #expect(store.draftTitle.isEmpty && store.draftBody.isEmpty && store.reviewBody.isEmpty)
        store.draftTitle = "Second destination"; store.reviewBody = "Unsent second review"
        store.saveDraft()

        try await fixture.git(["remote", "set-url", "origin", "https://github.com/acme/first.git"])
        await store.refresh()
        #expect(store.client?.repository.path == "acme/first")
        #expect(store.draftTitle == "First destination")
        #expect(store.draftBody == "First description")
        #expect(store.reviewBody == "Unsent first review")
        let restoredPreview = try #require(store.createPreview())
        if case .create(_, let originalID) = firstPreview.action, case .create(_, let restoredID) = restoredPreview.action {
            #expect(originalID == restoredID)
        } else { Issue.record("Expected creation previews") }

        try await fixture.git(["remote", "add", "upstream", "https://github.com/acme/third.git"])
        await store.connect()
        #expect(store.remotes.map(\.name) == ["origin", "upstream"])
        #expect(store.remoteName == "origin")
        #expect(store.draftTitle == "First destination")
        try await fixture.git(["remote", "remove", "origin"])
        await store.connect()
        #expect(store.remoteName == "upstream")
        #expect(store.client?.repository.path == "acme/third")
        try await fixture.git(["remote", "remove", "upstream"])
        await store.connect()
        #expect(store.client == nil)
        #expect(store.remotes.isEmpty)
    }

    @Test func remoteChangeDuringSubmissionPreflightNeverSendsWriteAndKeepsDraft() async throws {
        let fixture = try ReviewSessionFixture()
        defer { fixture.cleanUp() }
        let store = try await fixture.store()
        await store.connect()
        store.draftTitle = "Feature"; store.draftBody = "Retain this description"
        store.sourceBranch = "feature"; store.targetBranch = "main"
        let preview = try #require(store.createPreview())
        await fixture.fake.pauseNextList()
        let submitting = Task { await store.perform(preview) }
        while !(await fixture.fake.isPaused) { await Task.yield() }
        try await fixture.git(["remote", "set-url", "origin", "https://github.com/acme/changed.git"])
        await fixture.fake.release()
        _ = await submitting.value
        #expect(store.error?.contains("Git remote changed") == true)
        #expect(store.draftTitle == "Feature")
        #expect(store.draftBody == "Retain this description")
        #expect(await fixture.fake.snapshot().allSatisfy { $0.arguments[4] == "GET" })
    }

    @Test func toolChangeDuringAccountValidationNeverUsesOldClientForWrite() async throws {
        let fixture = try ReviewSessionFixture()
        defer { fixture.cleanUp() }
        let store = try await fixture.store()
        await store.connect()
        store.draftTitle = "Feature"; store.sourceBranch = "feature"; store.targetBranch = "main"
        let preview = try #require(store.createPreview())
        await fixture.fake.pauseNextUser()
        let submitting = Task { await store.perform(preview) }
        while !(await fixture.fake.isPaused) { await Task.yield() }
        store.updateTools(gitPath: GitDefaults.gitPath, ghPath: "/fake/replacement-gh", glabPath: nil)
        await fixture.fake.release()
        _ = await submitting.value
        #expect(store.error?.contains("settings changed") == true)
        #expect(store.draftTitle == "Feature")
        #expect(await fixture.fake.snapshot().allSatisfy { $0.arguments[4] == "GET" })
        await store.connect()
        #expect(store.client != nil)
        #expect(await fixture.fake.snapshot().last?.executable == "/fake/replacement-gh")
        #expect(store.draftTitle == "Feature")
    }
}
