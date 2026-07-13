import Foundation
import Testing
@testable import RepoDeckKit

/// Integration tests for push/pull behavior — `pushWithAutoRebase` above
/// all — against a local bare repository standing in for the remote. Fully
/// offline: `git push`/`git pull` over a filesystem path exercise the same
/// refspec and fast-forward logic as a network remote, minus transport.
@Suite struct GitClientSyncTests {
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

    private func headOID(in repo: URL) async throws -> String {
        let result = try await git(["rev-parse", "HEAD"], in: repo)
        return String(decoding: result.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Writes `content` to `name` in `repo`, stages everything, commits.
    private func commitFile(
        _ name: String, content: String, message: String, in repo: URL, client: GitClient
    ) async throws {
        try content.write(to: repo.appendingPathComponent(name), atomically: true, encoding: .utf8)
        try await client.stageAll(in: repo)
        try await client.commit(message: message, in: repo)
    }

    /// Creates a bare "remote" seeded with one commit, plus two clones with
    /// upstream tracking. `ours` is the repo under test; `theirs` simulates
    /// another machine pushing first. Seeding goes through a throwaway
    /// `seed` working repo because you cannot push to an empty clone
    /// without `-u`, and cloning a non-empty bare repo gives both clones a
    /// tracking `main` for free. Everything is removed unconditionally.
    private func withSharedRemote(
        _ body: (_ remote: URL, _ ours: URL, _ theirs: URL, _ client: GitClient) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("repodeck-sync-test-\(UUID().uuidString)", isDirectory: true)
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

        _ = try await ProcessRunner.run(arguments: ["clone", "--bare", seed.path, remote.path])
        _ = try await ProcessRunner.run(arguments: ["clone", remote.path, ours.path])
        _ = try await ProcessRunner.run(arguments: ["clone", remote.path, theirs.path])
        try await configureIdentity(in: ours)
        try await configureIdentity(in: theirs)

        try await body(remote, ours, theirs, GitClient())
    }

    // MARK: 1. Remote not ahead: plain push, no rebase

    @Test func returnsPushedWhenRemoteNotAhead() async throws {
        try await withSharedRemote { _, ours, _, client in
            try await commitFile("one.txt", content: "one\n", message: "feat: one", in: ours, client: client)

            let outcome = try await client.pushWithAutoRebase(in: ours)
            #expect(outcome == .pushed)

            let status = try await client.status(in: ours)
            #expect(status.ahead == 0)
        }
    }

    // MARK: 2. Rejection is classified (end-to-end, real stderr)

    @Test func staleClonePushIsRejectedAndClassified() async throws {
        try await withSharedRemote { _, ours, theirs, client in
            try await commitFile("theirs.txt", content: "t\n", message: "feat: theirs", in: theirs, client: client)
            try await client.push(in: theirs)

            try await commitFile("ours.txt", content: "o\n", message: "feat: ours", in: ours, client: client)

            do {
                try await client.push(in: ours)
                Issue.record("expected plain push from a stale clone to be rejected")
            } catch let error as GitError {
                #expect(error.isNonFastForwardPushRejection)
            }
        }
    }

    // MARK: 3. Happy path: remote ahead, no conflict — rebase and push

    @Test func rebasesAndPushesWhenRemoteAheadWithoutConflict() async throws {
        try await withSharedRemote { remote, ours, theirs, client in
            try await commitFile("theirs.txt", content: "t\n", message: "feat: theirs", in: theirs, client: client)
            try await client.push(in: theirs)

            try await commitFile("ours.txt", content: "o\n", message: "feat: ours", in: ours, client: client)

            let outcome = try await client.pushWithAutoRebase(in: ours)
            #expect(outcome == .rebasedAndPushed)

            // Both commits present locally; worktree clean; fully synced.
            let subjects = try await client.log(in: ours).map(\.subject)
            #expect(subjects.contains("feat: theirs"))
            #expect(subjects.contains("feat: ours"))
            let status = try await client.status(in: ours)
            #expect(status.changes.isEmpty)
            #expect(status.ahead == 0)
            #expect(status.behind == 0)

            // The rebased commit actually landed on the remote.
            let remoteLog = try await git(["log", "--format=%s", "main"], in: remote)
            #expect(String(decoding: remoteLog.stdout, as: UTF8.self).contains("feat: ours"))
        }
    }

    // MARK: 4. Conflict: rebase aborted, repo restored, error thrown

    @Test func conflictAbortsRebaseAndRestoresState() async throws {
        try await withSharedRemote { _, ours, theirs, client in
            // Both sides edit the same line of the same file.
            try await commitFile("base.txt", content: "theirs change\n", message: "feat: theirs", in: theirs, client: client)
            try await client.push(in: theirs)
            try await commitFile("base.txt", content: "ours change\n", message: "feat: ours", in: ours, client: client)

            let headBefore = try await headOID(in: ours)

            do {
                _ = try await client.pushWithAutoRebase(in: ours)
                Issue.record("expected the conflicting rebase to throw")
            } catch let error as GitError {
                #expect(error.command.contains("pull --rebase --autostash"))
            }

            // Never left mid-rebase; pre-rebase state restored.
            #expect(!FileManager.default.fileExists(atPath: ours.appendingPathComponent(".git/rebase-merge").path))
            #expect(!FileManager.default.fileExists(atPath: ours.appendingPathComponent(".git/rebase-apply").path))
            let headAfter = try await headOID(in: ours)
            #expect(headBefore == headAfter)
            let status = try await client.status(in: ours)
            #expect(status.changes.isEmpty)
        }
    }

    // MARK: 5. Non-rejection failure: no rebase attempted, error passthrough

    @Test func nonRejectionPushFailurePassesThroughWithoutRebase() async throws {
        try await withSharedRemote { _, ours, _, client in
            try await git(["remote", "set-url", "origin", "/nonexistent/remote.git"], in: ours)
            try await commitFile("x.txt", content: "x\n", message: "feat: x", in: ours, client: client)

            let headBefore = try await headOID(in: ours)

            do {
                _ = try await client.pushWithAutoRebase(in: ours)
                Issue.record("expected push to a nonexistent remote to fail")
            } catch let error as GitError {
                #expect(!error.isNonFastForwardPushRejection)
                #expect(error.command.hasSuffix(" push"))
            }

            #expect(try await headOID(in: ours) == headBefore)
            #expect(!FileManager.default.fileExists(atPath: ours.appendingPathComponent(".git/rebase-merge").path))
        }
    }

    // MARK: 6. Autostash: dirty tracked file survives the rebase-retry

    @Test func autostashPreservesUncommittedChanges() async throws {
        try await withSharedRemote { _, ours, theirs, client in
            try await commitFile("theirs.txt", content: "t\n", message: "feat: theirs", in: theirs, client: client)
            try await client.push(in: theirs)

            try await commitFile("ours.txt", content: "o\n", message: "feat: ours", in: ours, client: client)
            // Unstaged edit to a tracked file: blocks a plain `pull --rebase`;
            // `--autostash` is what makes this succeed.
            try "wip\n".write(to: ours.appendingPathComponent("base.txt"), atomically: true, encoding: .utf8)

            let outcome = try await client.pushWithAutoRebase(in: ours)
            #expect(outcome == .rebasedAndPushed)

            let content = try String(contentsOf: ours.appendingPathComponent("base.txt"), encoding: .utf8)
            #expect(content == "wip\n")
            let status = try await client.status(in: ours)
            #expect(status.changes.contains { $0.path == "base.txt" && $0.area == .unstaged })
        }
    }

    // MARK: 7. Autostash pop conflict: push still lands, changes kept in stash

    /// Pins the spec's documented edge case: the rebase succeeds, but
    /// re-applying the autostashed edit conflicts with the pulled commit.
    /// Expected (per git's autostash contract): the pull exits 0, the edit
    /// is retained in the stash, and the retry push proceeds. If this test
    /// fails because git exits non-zero here, do NOT force it to pass —
    /// report the observed behavior so the spec's edge-case note is updated.
    @Test func autostashPopConflictKeepsChangesInStashAndPushes() async throws {
        try await withSharedRemote { _, ours, theirs, client in
            try await commitFile("base.txt", content: "theirs change\n", message: "feat: theirs", in: theirs, client: client)
            try await client.push(in: theirs)

            try await commitFile("ours.txt", content: "o\n", message: "feat: ours", in: ours, client: client)
            // Uncommitted edit to the same file `theirs` just changed: the
            // rebase of `feat: ours` is clean, the autostash pop is not.
            try "ours wip\n".write(to: ours.appendingPathComponent("base.txt"), atomically: true, encoding: .utf8)

            let outcome = try await client.pushWithAutoRebase(in: ours)
            #expect(outcome == .rebasedAndPushed)

            let stashList = try await git(["stash", "list"], in: ours)
            #expect(!String(decoding: stashList.stdout, as: UTF8.self).isEmpty)
        }
    }
}
