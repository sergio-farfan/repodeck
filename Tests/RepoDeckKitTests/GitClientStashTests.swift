import Foundation
import Testing
@testable import RepoDeckKit

/// Integration tests for the `// MARK: - Stash` section of `GitClient.swift`:
/// `stashList`, `stashPush`, `stashApply`, `stashPop`, `stashDrop`. Mirrors
/// `GitClientIntegrationTests`'s harness style, seeded with one commit —
/// `git stash` needs an existing commit before it can stash a dirty change.
@Suite struct GitClientStashTests {
    /// Creates a unique temp git repo with one commit ("base.txt") and a
    /// stable, non-interactive identity, runs `body` against it, then
    /// removes the temp dir unconditionally.
    private func withTempRepo(_ body: (URL, GitClient) async throws -> Void) async throws {
        try await TestGitRepository.withRepository(baseContent: "base\n", body)
    }

    // MARK: 1. push (tracked change only) clears the dirty tree and appears in the list

    @Test func pushTrackedChangeClearsStatusAndAppearsInList() async throws {
        try await withTempRepo { repo, client in
            try "changed\n".write(to: repo.appendingPathComponent("base.txt"), atomically: true, encoding: .utf8)

            try await client.stashPush(message: "wip work", includeUntracked: false, in: repo)

            let status = try await client.status(in: repo)
            #expect(status.changes.isEmpty)

            let stashes = try await client.stashList(in: repo)
            #expect(stashes.count == 1)
            #expect(stashes[0].index == 0)
            #expect(stashes[0].subject.contains("wip work"))
        }
    }

    // MARK: 2. push --include-untracked also stashes untracked files

    @Test func pushIncludeUntrackedAlsoStashesUntrackedFiles() async throws {
        try await withTempRepo { repo, client in
            let untrackedURL = repo.appendingPathComponent("new.txt")
            try "untracked\n".write(to: untrackedURL, atomically: true, encoding: .utf8)

            try await client.stashPush(message: nil, includeUntracked: true, in: repo)

            let status = try await client.status(in: repo)
            #expect(status.changes.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: untrackedURL.path))

            let stashes = try await client.stashList(in: repo)
            #expect(stashes.count == 1)
        }
    }

    // MARK: 3. push without --include-untracked leaves untracked files on disk

    @Test func pushWithoutIncludeUntrackedLeavesUntrackedFilesUntouched() async throws {
        try await withTempRepo { repo, client in
            let trackedURL = repo.appendingPathComponent("base.txt")
            let untrackedURL = repo.appendingPathComponent("new.txt")
            try "changed\n".write(to: trackedURL, atomically: true, encoding: .utf8)
            try "untracked\n".write(to: untrackedURL, atomically: true, encoding: .utf8)

            try await client.stashPush(message: nil, includeUntracked: false, in: repo)

            #expect(FileManager.default.fileExists(atPath: untrackedURL.path))
            let status = try await client.status(in: repo)
            #expect(status.changes.count == 1)
            #expect(status.changes[0].area == .untracked)
        }
    }

    // MARK: 4. apply restores changes and keeps the stash in the list

    @Test func applyRestoresChangesAndKeepsStashInList() async throws {
        try await withTempRepo { repo, client in
            let fileURL = repo.appendingPathComponent("base.txt")
            try "changed\n".write(to: fileURL, atomically: true, encoding: .utf8)
            try await client.stashPush(message: "wip", includeUntracked: false, in: repo)

            try await client.stashApply(0, in: repo)

            let content = try String(contentsOf: fileURL, encoding: .utf8)
            #expect(content == "changed\n")
            let stashes = try await client.stashList(in: repo)
            #expect(stashes.count == 1)
        }
    }

    // MARK: 5. pop restores changes and removes the stash from the list

    @Test func popRestoresChangesAndRemovesStashFromList() async throws {
        try await withTempRepo { repo, client in
            let fileURL = repo.appendingPathComponent("base.txt")
            try "changed\n".write(to: fileURL, atomically: true, encoding: .utf8)
            try await client.stashPush(message: "wip", includeUntracked: false, in: repo)

            try await client.stashPop(0, in: repo)

            let content = try String(contentsOf: fileURL, encoding: .utf8)
            #expect(content == "changed\n")
            let stashes = try await client.stashList(in: repo)
            #expect(stashes.isEmpty)
        }
    }

    // MARK: 6. drop removes the stash without restoring its changes

    @Test func dropRemovesStashWithoutRestoringChanges() async throws {
        try await withTempRepo { repo, client in
            let fileURL = repo.appendingPathComponent("base.txt")
            try "changed\n".write(to: fileURL, atomically: true, encoding: .utf8)
            try await client.stashPush(message: "wip", includeUntracked: false, in: repo)

            try await client.stashDrop(0, in: repo)

            let content = try String(contentsOf: fileURL, encoding: .utf8)
            #expect(content == "base\n")
            let stashes = try await client.stashList(in: repo)
            #expect(stashes.isEmpty)
        }
    }

    // MARK: 7. apply on a conflicting dirty state surfaces a GitError

    @Test func applyOnConflictingDirtyStateThrowsGitError() async throws {
        try await withTempRepo { repo, client in
            let fileURL = repo.appendingPathComponent("base.txt")
            try "stashed-change\n".write(to: fileURL, atomically: true, encoding: .utf8)
            try await client.stashPush(message: "wip", includeUntracked: false, in: repo)

            // Dirty change to the same file the stash would restore — git
            // refuses with "local changes ... would be overwritten by merge"
            // rather than attempting a three-way merge.
            try "conflicting-dirty-change\n".write(to: fileURL, atomically: true, encoding: .utf8)

            do {
                try await client.stashApply(0, in: repo)
                Issue.record("expected apply to throw on conflicting dirty state")
            } catch let error as GitError {
                #expect(error.exitCode != 0)
            }
        }
    }

    // MARK: 8. pop on a conflicting dirty state surfaces a GitError and keeps the stash

    @Test func popOnConflictingDirtyStateThrowsGitErrorAndKeepsStash() async throws {
        try await withTempRepo { repo, client in
            let fileURL = repo.appendingPathComponent("base.txt")
            try "stashed-change\n".write(to: fileURL, atomically: true, encoding: .utf8)
            try await client.stashPush(message: "wip", includeUntracked: false, in: repo)

            try "conflicting-dirty-change\n".write(to: fileURL, atomically: true, encoding: .utf8)

            do {
                try await client.stashPop(0, in: repo)
                Issue.record("expected pop to throw on conflicting dirty state")
            } catch let error as GitError {
                #expect(error.exitCode != 0)
            }

            // git leaves the stash entry in place when pop fails to restore.
            let stashes = try await client.stashList(in: repo)
            #expect(stashes.count == 1)
        }
    }

    // MARK: 9. drop on an out-of-range index surfaces a GitError

    @Test func dropOnMissingStashThrowsGitError() async throws {
        try await withTempRepo { repo, client in
            do {
                try await client.stashDrop(0, in: repo)
                Issue.record("expected drop to throw when there is no stash")
            } catch let error as GitError {
                #expect(error.exitCode != 0)
            }
        }
    }

    @Test func selectedStashKeepsItsIdentityAfterNewStashesShiftIndices() async throws {
        try await withTempRepo { repo, client in
            let path = repo.appendingPathComponent("base.txt")
            try Data("selected\n".utf8).write(to: path)
            try await client.stashPush(message: "selected", includeUntracked: false, in: repo)
            let selected = try #require(try await client.stashList(in: repo).first)
            #expect(selected.oid != nil)
            try Data("newer\n".utf8).write(to: path)
            try await client.stashPush(message: "newer", includeUntracked: false, in: repo)
            let shifted = try #require(try await client.stashList(in: repo).last)
            #expect(selected.id == shifted.id)
            #expect(selected.index != shifted.index)
            try await client.stashPop(selected, in: repo)
            #expect(try Data(contentsOf: path) == Data("selected\n".utf8))
            let remaining = try await client.stashList(in: repo)
            #expect(remaining.count == 1)
            #expect(remaining[0].subject.contains("newer"))
        }
    }

    @Test func droppingStaleSelectionCannotDropItsReplacement() async throws {
        try await withTempRepo { repo, client in
            let path = repo.appendingPathComponent("base.txt")
            try Data("selected\n".utf8).write(to: path)
            try await client.stashPush(message: "selected", includeUntracked: false, in: repo)
            let selected = try #require(try await client.stashList(in: repo).first)
            try await client.stashDrop(selected, in: repo)
            try Data("replacement\n".utf8).write(to: path)
            try await client.stashPush(message: "replacement", includeUntracked: false, in: repo)
            await #expect(throws: GitError.self) { try await client.stashDrop(selected, in: repo) }
            #expect(try await client.stashList(in: repo).count == 1)
        }
    }
}
