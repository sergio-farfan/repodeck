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
        let result = try await ProcessRunner.run(arguments: ["-C", dir.path] + arguments)
        try #require(result.exitCode == 0, "git \(arguments.joined(separator: " ")) failed: \(result.stderr)")
        return result
    }

    private func configureIdentity(in repo: URL) async throws {
        try await git(["config", "user.email", "test@example.com"], in: repo)
        try await git(["config", "user.name", "Test"], in: repo)
        try await git(["config", "commit.gpgsign", "false"], in: repo)
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
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("repodeck-undo-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try await git(["init", "-b", "main"], in: root)
        try await configureIdentity(in: root)
        try "base\n".write(to: root.appendingPathComponent("base.txt"), atomically: true, encoding: .utf8)
        try await git(["add", "-A"], in: root)
        try await git(["commit", "-m", "chore: base"], in: root)

        try await body(root, GitClient())
    }

    /// Creates a bare "remote" seeded with one commit, plus two clones with
    /// upstream tracking. `ours` is the repo under test; `theirs` simulates
    /// another machine pushing first, so `ours` has something to pull.
    private func withSharedRemote(
        _ body: (_ remote: URL, _ ours: URL, _ theirs: URL, _ client: GitClient) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("repodeck-undo-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let seed = root.appendingPathComponent("seed", isDirectory: true)
        let remote = root.appendingPathComponent("remote.git", isDirectory: true)
        let ours = root.appendingPathComponent("ours", isDirectory: true)
        let theirs = root.appendingPathComponent("theirs", isDirectory: true)

        try FileManager.default.createDirectory(at: seed, withIntermediateDirectories: true)
        try await git(["init", "-b", "main"], in: seed)
        try await configureIdentity(in: seed)
        try "base\n".write(to: seed.appendingPathComponent("base.txt"), atomically: true, encoding: .utf8)
        try await git(["add", "-A"], in: seed)
        try await git(["commit", "-m", "chore: base"], in: seed)

        let cloneRemote = try await ProcessRunner.run(arguments: ["clone", "--bare", seed.path, remote.path])
        try #require(cloneRemote.exitCode == 0, "git clone failed: \(cloneRemote.stderr)")
        let cloneOurs = try await ProcessRunner.run(arguments: ["clone", remote.path, ours.path])
        try #require(cloneOurs.exitCode == 0, "git clone failed: \(cloneOurs.stderr)")
        let cloneTheirs = try await ProcessRunner.run(arguments: ["clone", remote.path, theirs.path])
        try #require(cloneTheirs.exitCode == 0, "git clone failed: \(cloneTheirs.stderr)")
        try await configureIdentity(in: ours)
        try await configureIdentity(in: theirs)

        try await body(remote, ours, theirs, GitClient())
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
}
