import Foundation
import Testing
import RepoDeckKit
@testable import RepoDeckCore

@Suite struct RepositoryDiscoveryTests {
    private func git(_ arguments: [String], in directory: URL) async throws {
        let result = try await ProcessRunner.run(arguments: ["-C", directory.path] + arguments,
            environment: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_COUNT": "0"])
        try #require(result.exitCode == 0, "Fixture git failed: \(result.stderr)")
    }
    private func fixture() async throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("discovery-\(UUID().uuidString)").resolvingSymlinksInPath()
        let main = root.appendingPathComponent("tracked/main")
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        try await git(["init", "-b", "main"], in: main)
        try await git(["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "initial"], in: main)
        return (root, main)
    }

    @Test func trackedRepoFindsSiblingAndNestedRegisteredWorktrees() async throws {
        let (root, main) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let sibling = root.appendingPathComponent("outside/sibling")
        let nested = main.appendingPathComponent("target/nested")
        try await git(["worktree", "add", "--detach", sibling.path, "HEAD"], in: main)
        try await git(["worktree", "add", "--detach", nested.path, "HEAD"], in: main)
        let repos = await RepositoryDiscovery.scan(roots: [main, main, sibling])
        #expect(Set(repos.map(\.id)) == Set([main.path, sibling.path, nested.path]))
        #expect(repos.count == 3)
    }

    @Test func bareStoreDiscoversCheckoutsWithoutDisplayingTheBareStore() async throws {
        let (root, main) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let bare = root.appendingPathComponent("store.git")
        let checkout = root.appendingPathComponent("checkout")
        try await git(["clone", "--bare", main.path, bare.path], in: root)
        try await git(["worktree", "add", "--detach", checkout.path, "HEAD"], in: bare)
        let repos = await RepositoryDiscovery.scan(roots: [bare])
        #expect(repos.map(\.id) == [checkout.path])
    }

    @Test func prunableMissingWorktreeIsNotShown() async throws {
        let (root, main) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let removed = root.appendingPathComponent("removed")
        try await git(["worktree", "add", "--detach", removed.path, "HEAD"], in: main)
        try FileManager.default.removeItem(at: removed)
        let repos = await RepositoryDiscovery.scan(roots: [main])
        #expect(repos.map(\.id) == [main.path])
    }

    @Test func worktreePathsKeepLiteralNewlinesAndExcludeBareEntries() {
        let raw = "worktree /repos/store.git\0bare\0\0worktree /repos/line\nbreak\0HEAD abc\0detached\0\0worktree /repos/missing\0prunable gitdir missing\0\0"
        #expect(RepositoryDiscovery.worktreePaths(from: Data(raw.utf8)).map(\.path) == ["/repos/line\nbreak"])
    }
}
