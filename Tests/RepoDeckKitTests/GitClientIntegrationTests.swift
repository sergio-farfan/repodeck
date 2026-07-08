import Foundation
import Testing
@testable import RepoDeckKit

/// Integration tests exercising `GitClient` against real, disposable git
/// repositories under `FileManager.default.temporaryDirectory`. No test ever
/// touches a real user repo, and none performs network operations (pull/push/
/// fetch are intentionally not covered here — their command construction is
/// identical in shape to the mutating commands that ARE tested).
@Suite struct GitClientIntegrationTests {
    /// Creates a unique temp git repo with a stable, non-interactive identity,
    /// runs `body` against it, then removes the temp dir unconditionally.
    private func withTempRepo(_ body: (URL, GitClient) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("repodeck-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try await ProcessRunner.run(arguments: ["init", "-b", "main"], workingDirectory: root)
        _ = try await ProcessRunner.run(arguments: ["-C", root.path, "config", "user.email", "test@example.com"])
        _ = try await ProcessRunner.run(arguments: ["-C", root.path, "config", "user.name", "Test"])
        _ = try await ProcessRunner.run(arguments: ["-C", root.path, "config", "commit.gpgsign", "false"])

        try await body(root, GitClient())
    }

    // MARK: 1. Fresh repo, no commits

    @Test func freshRepoHasNoCommits() async throws {
        try await withTempRepo { repo, client in
            let status = try await client.status(in: repo)
            #expect(status.branch == "main")
            #expect(status.oid == "(initial)")
            #expect(status.changes.isEmpty)

            // Exercises the exit-128 "does not have any commits" special case.
            let commits = try await client.log(in: repo)
            #expect(commits.isEmpty)
        }
    }

    // MARK: 2. Untracked file appears

    @Test func untrackedFileAppearsInStatus() async throws {
        try await withTempRepo { repo, client in
            let fileURL = repo.appendingPathComponent("untracked.txt")
            try "hello".write(to: fileURL, atomically: true, encoding: .utf8)

            let status = try await client.status(in: repo)
            #expect(status.changes.count == 1)
            let change = try #require(status.changes.first)
            #expect(change.path == "untracked.txt")
            #expect(change.area == .untracked)
            #expect(change.statusLetter == "U")
        }
    }

    // MARK: 3. Stage round-trip

    @Test func stageAndUnstageRoundTrip() async throws {
        try await withTempRepo { repo, client in
            let fileURL = repo.appendingPathComponent("file.txt")

            try "v1".write(to: fileURL, atomically: true, encoding: .utf8)
            try await client.stageAll(in: repo)
            try await client.commit(message: "feat: initial", in: repo)

            try "v2".write(to: fileURL, atomically: true, encoding: .utf8)
            try await client.stage(["file.txt"], in: repo)

            let stagedStatus = try await client.status(in: repo)
            let stagedChange = try #require(stagedStatus.changes.first { $0.area == .staged })
            #expect(stagedChange.statusLetter == "M")

            try await client.unstage(["file.txt"], in: repo)

            let unstagedStatus = try await client.status(in: repo)
            let unstagedChange = try #require(unstagedStatus.changes.first { $0.area == .unstaged })
            #expect(unstagedChange.statusLetter == "M")
        }
    }

    // MARK: 4. Commit clears status and appears in log

    @Test func commitClearsStatusAndAppearsInLog() async throws {
        try await withTempRepo { repo, client in
            let fileURL = repo.appendingPathComponent("file.txt")
            try "content".write(to: fileURL, atomically: true, encoding: .utf8)
            try await client.stage(["file.txt"], in: repo)
            try await client.commit(message: "feat: test commit", in: repo)

            let status = try await client.status(in: repo)
            #expect(status.changes.isEmpty)

            let commits = try await client.log(in: repo)
            #expect(commits.count == 1)
            let commit = try #require(commits.first)
            #expect(commit.subject == "feat: test commit")
            #expect(commit.author == "Test")
            #expect(!commit.hash.isEmpty)
            #expect(!commit.shortHash.isEmpty)
            #expect(commit.refs.contains("HEAD -> main"))
        }
    }

    // MARK: 5. stageAll stages multiple files

    @Test func stageAllStagesMultipleFiles() async throws {
        try await withTempRepo { repo, client in
            try "a".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            try "b".write(to: repo.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)

            try await client.stageAll(in: repo)

            let status = try await client.status(in: repo)
            let staged = status.changes.filter { $0.area == .staged }
            #expect(staged.count == 2)
            #expect(Set(staged.map(\.path)) == ["a.txt", "b.txt"])
        }
    }

    // MARK: 6. Error surface

    @Test func statusOnNonRepoThrowsGitError() async throws {
        let nonRepo = FileManager.default.temporaryDirectory
            .appendingPathComponent("repodeck-nonrepo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: nonRepo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: nonRepo) }

        let client = GitClient()
        do {
            _ = try await client.status(in: nonRepo)
            Issue.record("expected GitError to be thrown for a non-repo directory")
        } catch let error as GitError {
            #expect(error.exitCode != 0)
            #expect(!error.stderr.isEmpty)
        }
    }

    // MARK: 7. Path with spaces

    @Test func pathWithSpacesStagesAndCommits() async throws {
        try await withTempRepo { repo, client in
            let fileURL = repo.appendingPathComponent("my file.txt")
            try "content".write(to: fileURL, atomically: true, encoding: .utf8)

            try await client.stage(["my file.txt"], in: repo)
            try await client.commit(message: "feat: add file with spaces", in: repo)

            let status = try await client.status(in: repo)
            #expect(status.changes.isEmpty)

            let commits = try await client.log(in: repo)
            let commit = try #require(commits.first)
            #expect(commit.subject == "feat: add file with spaces")
        }
    }
}
