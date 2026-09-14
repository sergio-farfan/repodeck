import Foundation
import Testing
@testable import RepoDeckKit

/// Tests for the one-level undo API added to `GitClient` (see the
/// `// MARK: - Undo snapshots` section in `GitClient.swift`): `headOID`,
/// `writeUndoSnapshot`, `restoreUndoSnapshot`, and `discardUndoSnapshot`.
/// Mirrors `GitClientSyncTests`'s harness style — `withSharedRemote` for the
/// pull round-trip scenarios, a lightweight `withTempRepo` for the
/// ref-bookkeeping-only ones.
@Suite struct GitClientUndoTests {
    /// Runs `git -C <dir> <arguments>` directly (bypassing `GitClient`) for
    /// fixture setup and inspection, failing the test on non-zero exit.
    @discardableResult
    private func git(_ arguments: [String], in dir: URL) async throws -> ProcessResult {
        let result = try await TestGitRepository.run(arguments: ["-C", dir.path] + arguments)
        try #require(result.exitCode == 0, "git \(arguments.joined(separator: " ")) failed: \(result.stderr)")
        return result
    }



    /// Every `refs/repodeck/undo/*` ref currently present, via
    /// `git for-each-ref` (bypassing `GitClient`, purely for assertions).
    private func undoRefs(in repo: URL) async throws -> [String] {
        let result = try await git(["for-each-ref", "--format=%(refname)", "refs/repodeck/undo"], in: repo)
        return String(decoding: result.stdout, as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
    }

    /// Writes `content` to `name` in `repo`, stages everything, commits.
    private func commitFile(
        _ name: String, content: String, message: String, in repo: URL, client: GitClient
    ) async throws {
        try content.write(to: repo.appendingPathComponent(name), atomically: true, encoding: .utf8)
        try await client.stageAll(in: repo)
        try await client.commit(message: message, in: repo)
    }

    /// Creates a unique temp git repo with one commit and a stable,
    /// non-interactive identity, runs `body` against it, then removes the
    /// temp dir unconditionally. For tests that only exercise ref
    /// bookkeeping and don't need a remote to pull from.
    private func withTempRepo(_ body: (URL, GitClient) async throws -> Void) async throws {
        try await TestGitRepository.withRepository(baseContent: "base\n", body)
    }

    /// Creates a bare "remote" seeded with one commit, plus two clones with
    /// upstream tracking. `ours` is the repo under test; `theirs` simulates
    /// another machine pushing first, so `ours` has something to pull.
    private func withSharedRemote(
        _ body: (_ remote: URL, _ ours: URL, _ theirs: URL, _ client: GitClient) async throws -> Void
    ) async throws {
        try await TestGitRepository.withSharedRemote(body)
    }

    // MARK: 1. writeUndoSnapshot records current HEAD as a ref

    @Test func writeUndoSnapshotRecordsCurrentHead() async throws {
        try await withTempRepo { repo, client in
            let head = try await client.headOID(in: repo)
            let snapshot = try await client.writeUndoSnapshot(in: repo)

            #expect(snapshot.oid == head)
            let refs = try await undoRefs(in: repo)
            #expect(refs.contains(snapshot.refName))
        }
    }

    // MARK: 2. Pruning: two consecutive writes leave exactly one ref

    @Test func writeUndoSnapshotPrunesPriorSnapshots() async throws {
        try await withTempRepo { repo, client in
            let first = try await client.writeUndoSnapshot(in: repo)
            // Ref names are timestamped to the second; sleep so the two
            // writes land under distinct ref names and pruning is actually
            // exercised rather than trivially overwriting the same ref.
            try await Task.sleep(for: .seconds(1))
            let second = try await client.writeUndoSnapshot(in: repo)

            #expect(first.refName != second.refName)
            let refs = try await undoRefs(in: repo)
            #expect(refs == [second.refName])
        }
    }

    // MARK: 3. Pull-then-restore round trip

    @Test func restoreUndoSnapshotRoundTripsAfterPull() async throws {
        try await withSharedRemote { _, ours, theirs, client in
            try await commitFile("theirs.txt", content: "t\n", message: "feat: theirs", in: theirs, client: client)
            try await client.push(in: theirs)

            let snapshot = try await client.writeUndoSnapshot(in: ours)
            try await client.pull(in: ours)
            let postPullHead = try await client.headOID(in: ours)
            #expect(postPullHead != snapshot.oid)

            try await client.restoreUndoSnapshot(snapshot, expectedHead: postPullHead, in: ours)

            #expect(try await client.headOID(in: ours) == snapshot.oid)
            let refs = try await undoRefs(in: ours)
            #expect(refs.isEmpty)
        }
    }

    // MARK: 4. --keep preserves dirty work untouched by the restore

    @Test func restoreUndoSnapshotKeepsUnrelatedDirtyEdit() async throws {
        try await withSharedRemote { _, ours, theirs, client in
            try await commitFile("theirs.txt", content: "t\n", message: "feat: theirs", in: theirs, client: client)
            try await client.push(in: theirs)

            let snapshot = try await client.writeUndoSnapshot(in: ours)
            try await client.pull(in: ours)
            let postPullHead = try await client.headOID(in: ours)

            // Dirty edit to a file the pulled commit never touched.
            let dirtyEdit = "dirty edit -- untouched by pull\n"
            try dirtyEdit.write(to: ours.appendingPathComponent("base.txt"), atomically: true, encoding: .utf8)

            try await client.restoreUndoSnapshot(snapshot, expectedHead: postPullHead, in: ours)

            #expect(try await client.headOID(in: ours) == snapshot.oid)
            let content = try String(contentsOf: ours.appendingPathComponent("base.txt"), encoding: .utf8)
            #expect(content == dirtyEdit)
        }
    }

    // MARK: 5. --keep refuses when the restore would clobber a dirty edit

    @Test func restoreUndoSnapshotRefusesWhenItWouldClobberDirtyEdit() async throws {
        try await withSharedRemote { _, ours, theirs, client in
            try await commitFile("theirs.txt", content: "t\n", message: "feat: theirs", in: theirs, client: client)
            try await client.push(in: theirs)

            let snapshot = try await client.writeUndoSnapshot(in: ours)
            try await client.pull(in: ours)
            let postPullHead = try await client.headOID(in: ours)

            // Dirty edit to the very file the restore would remove.
            let dirtyEdit = "dirty edit -- must survive refusal\n"
            try dirtyEdit.write(to: ours.appendingPathComponent("theirs.txt"), atomically: true, encoding: .utf8)

            do {
                try await client.restoreUndoSnapshot(snapshot, expectedHead: postPullHead, in: ours)
                Issue.record("expected reset --keep to refuse and throw")
            } catch let error as GitError {
                #expect(error.command.contains("reset --keep"))
            }

            #expect(try await client.headOID(in: ours) == postPullHead)
            let content = try String(contentsOf: ours.appendingPathComponent("theirs.txt"), encoding: .utf8)
            #expect(content == dirtyEdit)
        }
    }

    // MARK: 6. Moved-on guard: stale expectedHead throws without side effects

    @Test func restoreUndoSnapshotThrowsWhenRepositoryMovedOn() async throws {
        try await withSharedRemote { _, ours, theirs, client in
            try await commitFile("theirs.txt", content: "t\n", message: "feat: theirs", in: theirs, client: client)
            try await client.push(in: theirs)

            let snapshot = try await client.writeUndoSnapshot(in: ours)
            try await client.pull(in: ours)
            let staleExpectedHead = try await client.headOID(in: ours)

            try await commitFile("ours.txt", content: "o\n", message: "feat: ours", in: ours, client: client)
            let movedOnHead = try await client.headOID(in: ours)

            do {
                try await client.restoreUndoSnapshot(snapshot, expectedHead: staleExpectedHead, in: ours)
                Issue.record("expected the moved-on guard to throw")
            } catch let error as GitError {
                #expect(error.stderr == "repository has moved on since the snapshot")
                #expect(error.command == "git reset --keep")
                #expect(error.exitCode == -1)
            }

            #expect(try await client.headOID(in: ours) == movedOnHead)
            let refs = try await undoRefs(in: ours)
            #expect(refs.contains(snapshot.refName))
        }
    }

    // MARK: 7. discardUndoSnapshot removes the ref; discarding twice is harmless

    @Test func discardUndoSnapshotRemovesRefAndIsIdempotent() async throws {
        try await withTempRepo { repo, client in
            let snapshot = try await client.writeUndoSnapshot(in: repo)

            await client.discardUndoSnapshot(snapshot, in: repo)
            var refs = try await undoRefs(in: repo)
            #expect(refs.isEmpty)

            await client.discardUndoSnapshot(snapshot, in: repo)
            refs = try await undoRefs(in: repo)
            #expect(refs.isEmpty)
        }
    }

    @Test func undoRejectsAnotherBranchAtTheSameCommit() async throws {
        try await withTempRepo { repo, client in
            let snapshot = try await client.writeUndoSnapshot(in: repo)
            try await commitFile("second.txt", content: "second\n", message: "second", in: repo, client: client)
            let expected = try await client.headOID(in: repo)
            try await git(["checkout", "-b", "feature"], in: repo)
            await #expect(throws: GitError.self) {
                try await client.restoreUndoSnapshot(snapshot, expectedHead: expected, in: repo)
            }
            #expect(try await client.headOID(in: repo) == expected)
            #expect(try await undoRefs(in: repo).contains(snapshot.refName))
            try await git(["checkout", "--detach", expected], in: repo)
            await #expect(throws: GitError.self) {
                try await client.restoreUndoSnapshot(snapshot, expectedHead: expected, in: repo)
            }
        }
    }

    @Test func worktreesAndBranchesKeepIndependentUndoReferences() async throws {
        try await withTempRepo { repo, client in
            let first = try await client.writeUndoSnapshot(in: repo)
            let linked = repo.appendingPathComponent("linked")
            try await git(["worktree", "add", "-b", "feature", linked.path], in: repo)
            let linkedSnapshot = try await client.writeUndoSnapshot(in: linked)
            #expect(first.worktreeGitDir != linkedSnapshot.worktreeGitDir)
            #expect(Set(try await undoRefs(in: repo)) == [first.refName, linkedSnapshot.refName])
            await #expect(throws: GitError.self) {
                try await client.restoreUndoSnapshot(first, expectedHead: first.oid, in: linked)
            }
            let replacement = try await client.writeUndoSnapshot(in: repo)
            #expect(Set(try await undoRefs(in: repo)) == [replacement.refName, linkedSnapshot.refName])
            try await git(["checkout", "-b", "another"], in: repo)
            let another = try await client.writeUndoSnapshot(in: repo)
            #expect(Set(try await undoRefs(in: repo)) == [replacement.refName, linkedSnapshot.refName, another.refName])
        }
    }
}
