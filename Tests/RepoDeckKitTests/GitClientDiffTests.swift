import Foundation
import Testing
@testable import RepoDeckKit

/// Integration tests for the `// MARK: - Diff` section of `GitClient.swift`:
/// `diff`, `diffUntracked`, `diffCommit`. Mirrors `GitClientIntegrationTests`'s
/// harness style, seeded with one commit so both staged/unstaged variants have
/// something to compare against.
@Suite struct GitClientDiffTests {
    /// Creates a unique temp git repo with one commit ("base.txt") and a
    /// stable, non-interactive identity, runs `body` against it, then
    /// removes the temp dir unconditionally.
    private func withTempRepo(_ body: (URL, GitClient) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("repodeck-diff-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try await ProcessRunner.run(arguments: ["init", "-b", "main"], workingDirectory: root)
        _ = try await ProcessRunner.run(arguments: ["-C", root.path, "config", "user.email", "test@example.com"])
        _ = try await ProcessRunner.run(arguments: ["-C", root.path, "config", "user.name", "Test"])
        _ = try await ProcessRunner.run(arguments: ["-C", root.path, "config", "commit.gpgsign", "false"])

        let client = GitClient()
        try "base1\nbase2\nbase3\n".write(to: root.appendingPathComponent("base.txt"), atomically: true, encoding: .utf8)
        try await client.stageAll(in: root)
        try await client.commit(message: "chore: base", in: root)

        try await body(root, client)
    }

    // MARK: 1. Unstaged modification produces the expected hunk

    @Test func unstagedModificationProducesExpectedHunk() async throws {
        try await withTempRepo { repo, client in
            try "base1\nCHANGED\nbase3\n".write(to: repo.appendingPathComponent("base.txt"), atomically: true, encoding: .utf8)

            let diff = try await client.diff(path: "base.txt", staged: false, in: repo)
            let unwrapped = try #require(diff)
            #expect(unwrapped.oldPath == "base.txt")
            #expect(unwrapped.newPath == "base.txt")
            #expect(unwrapped.hunks.count == 1)
            #expect(unwrapped.hunks[0].lines.map(\.text) == ["base1", "base2", "CHANGED", "base3"])
        }
    }

    // MARK: 2. Staging moves the diff from unstaged to staged

    @Test func stagingMovesTheDiffFromUnstagedToStaged() async throws {
        try await withTempRepo { repo, client in
            let fileURL = repo.appendingPathComponent("base.txt")
            try "base1\nCHANGED\nbase3\n".write(to: fileURL, atomically: true, encoding: .utf8)
            try await client.stage(["base.txt"], in: repo)

            let staged = try await client.diff(path: "base.txt", staged: true, in: repo)
            #expect(staged != nil)
            #expect(staged?.hunks.first?.lines.map(\.text) == ["base1", "base2", "CHANGED", "base3"])

            let unstaged = try await client.diff(path: "base.txt", staged: false, in: repo)
            #expect(unstaged == nil)
        }
    }

    // MARK: 3. A file with no changes has no diff

    @Test func fileWithNoChangesHasNoDiff() async throws {
        try await withTempRepo { repo, client in
            let diff = try await client.diff(path: "base.txt", staged: false, in: repo)
            #expect(diff == nil)
        }
    }

    // MARK: 4. Untracked file shows as an all-addition diff with a repo-relative path

    @Test func untrackedFileShowsAsAllAdditionDiffWithRepoRelativePath() async throws {
        try await withTempRepo { repo, client in
            try "new1\nnew2\n".write(to: repo.appendingPathComponent("untracked.txt"), atomically: true, encoding: .utf8)

            let diff = try await client.diffUntracked(path: "untracked.txt", in: repo)
            let unwrapped = try #require(diff)
            #expect(unwrapped.oldPath == "/dev/null")
            #expect(unwrapped.newPath == "untracked.txt")
            #expect(unwrapped.hunks.count == 1)
            #expect(unwrapped.hunks[0].lines.allSatisfy { $0.kind == .addition })
            #expect(unwrapped.hunks[0].lines.map(\.text) == ["new1", "new2"])
        }
    }

    // MARK: 5. Untracked file in a subdirectory keeps the repo-relative path

    @Test func untrackedFileInSubdirectoryKeepsRepoRelativePath() async throws {
        try await withTempRepo { repo, client in
            let subdir = repo.appendingPathComponent("sub", isDirectory: true)
            try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
            try "nested\n".write(to: subdir.appendingPathComponent("nested.txt"), atomically: true, encoding: .utf8)

            let diff = try await client.diffUntracked(path: "sub/nested.txt", in: repo)
            let unwrapped = try #require(diff)
            #expect(unwrapped.newPath == "sub/nested.txt")
            #expect(unwrapped.displayPath == "sub/nested.txt")
        }
    }

    // MARK: 6. Commit with two files returns both FileDiffs

    @Test func commitWithTwoFilesReturnsBothFileDiffs() async throws {
        try await withTempRepo { repo, client in
            try "a1\na2\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            try "b1\nb2\n".write(to: repo.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
            try await client.stageAll(in: repo)
            try await client.commit(message: "feat: add a and b", in: repo)

            let head = try await client.headOID(in: repo)
            let diffs = try await client.diffCommit(head, in: repo)

            #expect(diffs.count == 2)
            #expect(Set(diffs.map(\.newPath)) == ["a.txt", "b.txt"])
            #expect(diffs.allSatisfy { $0.hunks.first?.lines.allSatisfy { $0.kind == .addition } ?? false })
        }
    }

    // MARK: 7. A binary file's diff is flagged isBinary with no hunks

    @Test func binaryFileDiffIsFlaggedIsBinaryWithNoHunks() async throws {
        try await withTempRepo { repo, client in
            let fileURL = repo.appendingPathComponent("bin.dat")
            try Data([0x00, 0x01, 0x02, 0x00, 0xFF]).write(to: fileURL)
            try await client.stageAll(in: repo)
            try await client.commit(message: "chore: add binary", in: repo)

            try Data([0x00, 0x01, 0x02, 0xAA, 0xFF, 0x00]).write(to: fileURL)

            let diff = try await client.diff(path: "bin.dat", staged: false, in: repo)
            let unwrapped = try #require(diff)
            #expect(unwrapped.isBinary == true)
            #expect(unwrapped.hunks.isEmpty)
        }
    }
}
