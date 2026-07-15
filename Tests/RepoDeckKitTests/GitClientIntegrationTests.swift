import Foundation
import Testing
@testable import RepoDeckKit

/// Integration tests exercising `GitClient` against real, disposable git
/// repositories under `FileManager.default.temporaryDirectory`. No test ever
/// touches a real user repo, and none reaches the network — push/pull flows
/// are covered in `GitClientSyncTests` using a local bare repo as the remote.
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

    // MARK: 8. Truncated status output is a partial parse, not a thrown error

    @Test func truncatedStatusOutputDoesNotThrowAndReportsPartialResults() async throws {
        try await withTempRepo { repo, _ in
            for i in 0..<20 {
                let name = "untracked-file-with-a-reasonably-long-name-\(i).txt"
                try "content".write(to: repo.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }

            var client = GitClient()
            client.statusOutputLimit = 64

            let status = try await client.status(in: repo)
            #expect(status.didHitLimit == true)
            #expect(status.changes.count >= 1)
            #expect(status.changes.count < 20)
        }
    }

    // MARK: 9. Hunk-level staging (PatchBuilder + GitClient.applyPatch)

    /// `git -C <repo> diff --cached -- <path>` via a direct call (not
    /// `client.diff`, which pins config unrelated to what these tests
    /// assert) — used to inspect exactly what landed in the index.
    private func cachedDiffText(_ path: String, in repo: URL) async throws -> String {
        let result = try await ProcessRunner.run(
            arguments: ["-C", repo.path, "diff", "--cached", "--", path]
        )
        return String(decoding: result.stdout, as: UTF8.self)
    }

    @Test func stagingTheMiddleOfThreeHunksLeavesTheOtherTwoUnstagedThenReverseUnstagesIt() async throws {
        try await withTempRepo { repo, client in
            let fileURL = repo.appendingPathComponent("file.txt")
            let originalLines = (1...30).map { "line\($0)" }
            try (originalLines.joined(separator: "\n") + "\n")
                .write(to: fileURL, atomically: true, encoding: .utf8)
            try await client.stageAll(in: repo)
            try await client.commit(message: "feat: initial", in: repo)

            // Three well-separated single-line edits, each far enough apart
            // (10 lines) that git's default 3-line context keeps them as
            // three distinct hunks rather than merging any two.
            var modifiedLines = originalLines
            modifiedLines[4] = "line5-CHANGED"    // hunk 0
            modifiedLines[14] = "line15-CHANGED"  // hunk 1 (the one under test)
            modifiedLines[24] = "line25-CHANGED"  // hunk 2
            try (modifiedLines.joined(separator: "\n") + "\n")
                .write(to: fileURL, atomically: true, encoding: .utf8)

            let fileDiff = try #require(try await client.diff(path: "file.txt", staged: false, in: repo))
            #expect(fileDiff.hunks.count == 3)

            let middleHunk = fileDiff.hunks[1]
            let patch = PatchBuilder.patch(for: middleHunk, in: fileDiff, reverse: false)

            try await client.applyPatch(patch, cached: true, reverse: false, in: repo)

            // Both staged (the middle hunk) and unstaged (the other two)
            // changes exist for the same file simultaneously.
            let status = try await client.status(in: repo)
            let staged = status.changes.filter { $0.area == .staged }
            let unstaged = status.changes.filter { $0.area == .unstaged }
            #expect(staged.map(\.path) == ["file.txt"])
            #expect(unstaged.map(\.path) == ["file.txt"])

            let staged1 = try await cachedDiffText("file.txt", in: repo)
            #expect(staged1.contains("line15-CHANGED"))
            #expect(!staged1.contains("line5-CHANGED"))
            #expect(!staged1.contains("line25-CHANGED"))

            // Reverse-apply the same hunk (unstage): the index goes back to
            // clean for this file, the two other edits remain unstaged.
            try await client.applyPatch(patch, cached: true, reverse: true, in: repo)

            let staged2 = try await cachedDiffText("file.txt", in: repo)
            #expect(staged2.isEmpty)

            let finalStatus = try await client.status(in: repo)
            #expect(finalStatus.changes.filter { $0.area == .staged }.isEmpty)
            #expect(finalStatus.changes.filter { $0.area == .unstaged }.map(\.path) == ["file.txt"])
        }
    }

    @Test func crlfHunkAppliesCleanly() async throws {
        try await withTempRepo { repo, client in
            let fileURL = repo.appendingPathComponent("crlf.txt")
            let originalLines = (1...10).map { "line\($0)" }
            try Data((originalLines.joined(separator: "\r\n") + "\r\n").utf8).write(to: fileURL)
            try await client.stageAll(in: repo)
            try await client.commit(message: "feat: crlf initial", in: repo)

            var modifiedLines = originalLines
            modifiedLines[4] = "line5-CHANGED"
            try Data((modifiedLines.joined(separator: "\r\n") + "\r\n").utf8).write(to: fileURL)

            let fileDiff = try #require(try await client.diff(path: "crlf.txt", staged: false, in: repo))
            #expect(fileDiff.hunks.count == 1)
            let hunk = fileDiff.hunks[0]
            // The CRLF fidelity this exercises: DiffLine.text keeps the \r.
            #expect(hunk.lines.contains { $0.text.hasSuffix("\r") })

            let patch = PatchBuilder.patch(for: hunk, in: fileDiff, reverse: false)
            try await client.applyPatch(patch, cached: true, reverse: false, in: repo)

            let staged = try await cachedDiffText("crlf.txt", in: repo)
            #expect(staged.contains("line5-CHANGED"))
        }
    }

    @Test func noNewlineAtEndOfFileHunkAppliesCleanly() async throws {
        try await withTempRepo { repo, client in
            let fileURL = repo.appendingPathComponent("nonl.txt")
            // No trailing newline on the last line.
            try Data("line1\nline2\nline3".utf8).write(to: fileURL)
            try await client.stageAll(in: repo)
            try await client.commit(message: "feat: no-newline initial", in: repo)

            try Data("line1\nline2\nline3-CHANGED".utf8).write(to: fileURL)

            let fileDiff = try #require(try await client.diff(path: "nonl.txt", staged: false, in: repo))
            #expect(fileDiff.hunks.count == 1)
            let hunk = fileDiff.hunks[0]
            #expect(hunk.lines.contains { $0.noNewlineAtEOF })

            let patch = PatchBuilder.patch(for: hunk, in: fileDiff, reverse: false)
            try await client.applyPatch(patch, cached: true, reverse: false, in: repo)

            let staged = try await cachedDiffText("nonl.txt", in: repo)
            #expect(staged.contains("line3-CHANGED"))
        }
    }

    /// `git ls-files --cached` via a direct call — used to assert the index
    /// never gained a bogus path (e.g. a literal `dev/null` entry from a
    /// mis-built `diff --git` line).
    private func cachedPaths(in repo: URL) async throws -> [String] {
        let result = try await ProcessRunner.run(arguments: ["-C", repo.path, "ls-files", "--cached"])
        return String(decoding: result.stdout, as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
    }

    // MARK: 10. New-file hunk (Fix 1) — real `git apply --cached` against an add

    @Test func newFileHunkStagesAsAddedFileWithoutABogusDevNullPath() async throws {
        try await withTempRepo { repo, client in
            let fileURL = repo.appendingPathComponent("new.txt")
            try "hello\n".write(to: fileURL, atomically: true, encoding: .utf8)

            let fileDiff = try #require(try await client.diffUntracked(path: "new.txt", in: repo))
            #expect(fileDiff.oldPath == "/dev/null")
            #expect(fileDiff.hunks.count == 1)
            let hunk = fileDiff.hunks[0]

            let patch = PatchBuilder.patch(for: hunk, in: fileDiff, reverse: false)
            try await client.applyPatch(patch, cached: true, reverse: false, in: repo)

            let status = try await client.status(in: repo)
            let staged = try #require(status.changes.first { $0.area == .staged && $0.path == "new.txt" })
            #expect(staged.statusLetter == "A")

            let paths = try await cachedPaths(in: repo)
            #expect(paths.contains("new.txt"))
            #expect(!paths.contains { $0.contains("dev/null") })
        }
    }

    // MARK: 11. Deleted-file hunk (Fix 1) — real `git apply --cached` against a delete

    @Test func deletedFileHunkStagesDeletionWithoutABogusDevNullPath() async throws {
        try await withTempRepo { repo, client in
            let fileURL = repo.appendingPathComponent("old.txt")
            try "hello\n".write(to: fileURL, atomically: true, encoding: .utf8)
            try await client.stageAll(in: repo)
            try await client.commit(message: "feat: initial", in: repo)

            try FileManager.default.removeItem(at: fileURL)

            let fileDiff = try #require(try await client.diff(path: "old.txt", staged: false, in: repo))
            #expect(fileDiff.newPath == "/dev/null")
            #expect(fileDiff.hunks.count == 1)
            let hunk = fileDiff.hunks[0]

            let patch = PatchBuilder.patch(for: hunk, in: fileDiff, reverse: false)
            try await client.applyPatch(patch, cached: true, reverse: false, in: repo)

            let status = try await client.status(in: repo)
            let staged = try #require(status.changes.first { $0.area == .staged && $0.path == "old.txt" })
            #expect(staged.statusLetter == "D")

            let paths = try await cachedPaths(in: repo)
            #expect(!paths.contains("old.txt"))
            #expect(!paths.contains { $0.contains("dev/null") })
        }
    }

    // MARK: 12. One-line file (Fix 3) — proves the explicit ",1" header form

    @Test func oneLineFileChangeProducesExplicitCountOneHunkThatRealGitAccepts() async throws {
        try await withTempRepo { repo, client in
            let fileURL = repo.appendingPathComponent("single.txt")
            try "hello\n".write(to: fileURL, atomically: true, encoding: .utf8)
            try await client.stageAll(in: repo)
            try await client.commit(message: "feat: single-line initial", in: repo)

            try "world\n".write(to: fileURL, atomically: true, encoding: .utf8)

            let fileDiff = try #require(try await client.diff(path: "single.txt", staged: false, in: repo))
            #expect(fileDiff.hunks.count == 1)
            let hunk = fileDiff.hunks[0]
            // No surrounding context is possible in a one-line file: the
            // computed old/new counts are both 1.
            #expect(hunk.oldCount == 1)
            #expect(hunk.newCount == 1)

            let patch = PatchBuilder.patch(for: hunk, in: fileDiff, reverse: false)
            #expect(patch.contains("@@ -1,1 +1,1 @@"))
            try await client.applyPatch(patch, cached: true, reverse: false, in: repo)

            let staged = try await cachedDiffText("single.txt", in: repo)
            #expect(staged.contains("+world"))
            #expect(staged.contains("-hello"))
        }
    }
}
