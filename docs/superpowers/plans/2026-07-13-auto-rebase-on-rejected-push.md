# Auto-Rebase on Rejected Push Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Per-repo opt-in toggle: when a push is rejected as non-fast-forward, automatically `git pull --rebase --autostash` and retry the push once, with a dismissible notice on success.

**Architecture:** Policy execution lives in `RepoDeckKit` as a new `GitClient.pushWithAutoRebase(in:)` composite plus a `GitError` classification predicate; policy storage lives in the app layer as a `UserDefaults`-persisted set on `AppModel` (mirroring `pinnedRepoIDs`), threaded onto each `RepoViewModel`. UI is a checkable context-menu item on the repo row and a new info banner beside the existing error banner.

**Tech Stack:** Swift 6 (SPM), SwiftUI (macOS), swift-testing (`@Suite`/`@Test`/`#expect`/`#require`), system git via `ProcessRunner`.

**Spec:** `docs/superpowers/specs/2026-07-13-auto-rebase-on-rejected-push-design.md`

## Global Constraints

- Build: `swift build`. Tests: `swift test` (run plainly — no output-truncating pipes; per project CLAUDE.md).
- Tests use swift-testing (`import Testing`), NOT XCTest, and live in `Tests/RepoDeckKitTests/`.
- `@AppStorage` does not work inside `@Observable` classes — persist via `UserDefaults.standard` directly (existing pattern).
- All view models are `@MainActor @Observable` (Swift Observation, not `ObservableObject`).
- No test may touch a real user repo or the network: fixtures under `FileManager.default.temporaryDirectory`, local bare repos as remotes.
- Commits: conventional (`feat:`, `docs:` …), committed directly to `main` (this repo's convention — no feature branches).
- No emojis anywhere. Never credit Claude/Claude Code as author or co-author in any commit, comment, or doc.
- Default behavior with the toggle off must be byte-for-byte unchanged.

---

### Task 1: `GitError.isNonFastForwardPushRejection` predicate

**Files:**
- Modify: `Sources/RepoDeckKit/Git/GitError.swift`
- Create: `Tests/RepoDeckKitTests/GitErrorTests.swift`

**Interfaces:**
- Consumes: existing `GitError` (`command: String`, `exitCode: Int32`, `stderr: String`).
- Produces: `public var isNonFastForwardPushRejection: Bool` on `GitError` — used by Task 2's composite.

- [ ] **Step 1: Write the failing tests**

Create `Tests/RepoDeckKitTests/GitErrorTests.swift`:

```swift
import Testing
@testable import RepoDeckKit

/// Unit tests for `GitError.isNonFastForwardPushRejection` against canned
/// stderr in git's `LC_ALL=C` (untranslated) form — the only form the app
/// ever sees, because `ProcessRunner` forces `LC_ALL=C` on every child.
@Suite struct GitErrorTests {
    private func pushError(stderr: String) -> GitError {
        GitError(command: "git -C /tmp/repo push", exitCode: 1, stderr: stderr)
    }

    @Test func fetchFirstRejectionIsClassified() {
        let stderr = """
        To /tmp/remote.git
         ! [rejected]        main -> main (fetch first)
        error: failed to push some refs to '/tmp/remote.git'
        hint: Updates were rejected because the remote contains work that you do not
        hint: have locally.
        """
        #expect(pushError(stderr: stderr).isNonFastForwardPushRejection)
    }

    @Test func nonFastForwardRejectionIsClassified() {
        let stderr = """
        To /tmp/remote.git
         ! [rejected]        main -> main (non-fast-forward)
        error: failed to push some refs to '/tmp/remote.git'
        """
        #expect(pushError(stderr: stderr).isNonFastForwardPushRejection)
    }

    @Test func authFailureIsNotClassified() {
        let stderr = "fatal: could not read Username for 'https://example.com': terminal prompts disabled"
        #expect(!pushError(stderr: stderr).isNonFastForwardPushRejection)
    }

    @Test func missingUpstreamIsNotClassified() {
        let stderr = """
        fatal: The current branch main has no upstream branch.
        To push the current branch and set the remote as upstream, use

            git push --set-upstream origin main
        """
        #expect(!pushError(stderr: stderr).isNonFastForwardPushRejection)
    }

    @Test func staleInfoForceWithLeaseIsNotClassified() {
        let stderr = """
        To /tmp/remote.git
         ! [rejected]        main -> main (stale info)
        error: failed to push some refs to '/tmp/remote.git'
        """
        #expect(!pushError(stderr: stderr).isNonFastForwardPushRejection)
    }

    @Test func emptyStderrIsNotClassified() {
        #expect(!pushError(stderr: "").isNonFastForwardPushRejection)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter GitErrorTests`
Expected: compile FAILURE — `value of type 'GitError' has no member 'isNonFastForwardPushRejection'`.

- [ ] **Step 3: Implement the predicate**

In `Sources/RepoDeckKit/Git/GitError.swift`, add below `errorDescription` (before `init`):

```swift
    /// True when this error is a push rejected as non-fast-forward — the
    /// remote has commits the local branch doesn't. Matching stderr text is
    /// locale-stable because `ProcessRunner` forces `LC_ALL=C` on every
    /// child process. "stale info" (a `--force-with-lease` artifact) is
    /// deliberately excluded — RepoDeck never force-pushes.
    public var isNonFastForwardPushRejection: Bool {
        stderr.contains("[rejected]")
            && (stderr.contains("non-fast-forward") || stderr.contains("fetch first"))
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter GitErrorTests`
Expected: 6 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/RepoDeckKit/Git/GitError.swift Tests/RepoDeckKitTests/GitErrorTests.swift
git commit -m "feat: classify non-fast-forward push rejections in GitError"
```

---

### Task 2: `GitClient.pushWithAutoRebase(in:)` composite

**Files:**
- Modify: `Sources/RepoDeckKit/Git/GitClient.swift` (after `push(in:)`, around line 104)
- Create: `Tests/RepoDeckKitTests/GitClientSyncTests.swift`
- Modify: `Tests/RepoDeckKitTests/GitClientIntegrationTests.swift:5-9` (header comment only)

**Interfaces:**
- Consumes: `GitError.isNonFastForwardPushRejection` (Task 1); private `runVoid(_:in:)` helper already in `GitClient`.
- Produces: `public enum PushOutcome: Sendable, Equatable { case pushed, rebasedAndPushed }` (top level in `GitClient.swift`) and `public func pushWithAutoRebase(in repo: URL) async throws -> PushOutcome` — used by Task 3's `RepoViewModel.push()`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/RepoDeckKitTests/GitClientSyncTests.swift`:

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter GitClientSyncTests`
Expected: compile FAILURE — `value of type 'GitClient' has no member 'pushWithAutoRebase'`.

- [ ] **Step 3: Implement `PushOutcome` and the composite**

In `Sources/RepoDeckKit/Git/GitClient.swift`:

Top level, above `public struct GitClient` (after the imports):

```swift
/// Outcome of `GitClient.pushWithAutoRebase(in:)`: whether the push landed
/// on the first attempt or required a rebase-and-retry.
public enum PushOutcome: Sendable, Equatable {
    case pushed
    case rebasedAndPushed
}
```

Inside `GitClient`, immediately after `push(in:)` (line 102-104):

```swift
    /// `git push`, with automatic recovery from a non-fast-forward
    /// rejection: on rejection, runs `git pull --rebase --autostash` and
    /// retries the push exactly once. Any other push failure — and the
    /// retry's own failure — is rethrown unchanged, with no rebase
    /// attempted. If the rebase itself fails (e.g. conflicts), a
    /// best-effort `git rebase --abort` restores the pre-pull state before
    /// the pull's error is rethrown, so the repo is never left mid-rebase;
    /// the abort's own result is ignored because it fails harmlessly when
    /// the pull never actually started a rebase.
    public func pushWithAutoRebase(in repo: URL) async throws -> PushOutcome {
        do {
            try await runVoid(["push"], in: repo)
            return .pushed
        } catch let error as GitError where error.isNonFastForwardPushRejection {
            do {
                try await runVoid(["pull", "--rebase", "--autostash"], in: repo)
            } catch let pullError as GitError {
                try? await runVoid(["rebase", "--abort"], in: repo)
                throw pullError
            }
            try await runVoid(["push"], in: repo)
            return .rebasedAndPushed
        }
    }
```

- [ ] **Step 4: Update the stale test-suite header comment**

In `Tests/RepoDeckKitTests/GitClientIntegrationTests.swift`, replace lines 5-9:

```swift
/// Integration tests exercising `GitClient` against real, disposable git
/// repositories under `FileManager.default.temporaryDirectory`. No test ever
/// touches a real user repo, and none performs network operations (pull/push/
/// fetch are intentionally not covered here — their command construction is
/// identical in shape to the mutating commands that ARE tested).
```

with:

```swift
/// Integration tests exercising `GitClient` against real, disposable git
/// repositories under `FileManager.default.temporaryDirectory`. No test ever
/// touches a real user repo, and none reaches the network — push/pull flows
/// are covered in `GitClientSyncTests` using a local bare repo as the remote.
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter GitClientSyncTests`
Expected: 7 tests PASS. If test 7 (`autostashPopConflictKeepsChangesInStashAndPushes`) fails on git's exit code, stop and report the observed stderr/exit code instead of changing the assertion — the spec's edge-case note must be corrected to match reality.

Then run the full suite: `swift test`
Expected: all tests PASS (no regressions).

- [ ] **Step 6: Commit**

```bash
git add Sources/RepoDeckKit/Git/GitClient.swift Tests/RepoDeckKitTests/GitClientSyncTests.swift Tests/RepoDeckKitTests/GitClientIntegrationTests.swift
git commit -m "feat: add pushWithAutoRebase composite to GitClient"
```

---

### Task 3: Per-repo policy storage and view-model wiring

**Files:**
- Modify: `Sources/RepoDeck/ViewModels/AppModel.swift`
- Modify: `Sources/RepoDeck/ViewModels/RepoViewModel.swift`

**Interfaces:**
- Consumes: `GitClient.pushWithAutoRebase(in:) -> PushOutcome` and `PushOutcome.rebasedAndPushed` (Task 2).
- Produces: `AppModel.autoRebaseRepoIDs: Set<String>`, `AppModel.toggleAutoRebase(_ id: String)`, `RepoViewModel.autoRebaseOnRejectedPush: Bool`, `RepoViewModel.actionNotice: String?` — used by Task 4's views.

The app target has no unit-test harness (tests cover `RepoDeckKit` only); this task's verification is `swift build` plus review. Keep the layer thin.

- [ ] **Step 1: Add the persisted set to `AppModel`**

In `Sources/RepoDeck/ViewModels/AppModel.swift`:

After line 14 (`private static let pinnedRepoIDsKey = "pinnedRepoIDs"`):

```swift
    private static let autoRebaseRepoIDsKey = "autoRebaseRepoIDs"
```

After line 32 (`var pinnedRepoIDs: Set<String>`):

```swift
    /// Repos (by id, i.e. path) with "auto-rebase on rejected push" enabled.
    /// Persisted like `pinnedRepoIDs`; mirrored onto each `RepoViewModel`'s
    /// `autoRebaseOnRejectedPush` flag, which is what `push()` reads.
    var autoRebaseRepoIDs: Set<String>
```

In `init()`, after the `pinnedRepoIDs` load (lines 64-65):

```swift
        let autoRebaseIDs = UserDefaults.standard.stringArray(forKey: Self.autoRebaseRepoIDsKey) ?? []
        autoRebaseRepoIDs = Set(autoRebaseIDs)
```

- [ ] **Step 2: Add `toggleAutoRebase` and seed new view models in `rescan()`**

After `togglePin(_:)` (lines 92-99):

```swift
    /// Adds or removes `id` from the auto-rebase set, persists it, and
    /// updates the live view model's flag so the next Push picks it up.
    func toggleAutoRebase(_ id: String) {
        if autoRebaseRepoIDs.contains(id) {
            autoRebaseRepoIDs.remove(id)
        } else {
            autoRebaseRepoIDs.insert(id)
        }
        UserDefaults.standard.set(Array(autoRebaseRepoIDs), forKey: Self.autoRebaseRepoIDsKey)
        repos.first { $0.id == id }?.autoRebaseOnRejectedPush = autoRebaseRepoIDs.contains(id)
    }
```

In `rescan()`, replace (lines 234-237):

```swift
        let existingByID = Dictionary(uniqueKeysWithValues: repos.map { ($0.id, $0) })
        repos = deduped.map { repo in
            existingByID[repo.id] ?? RepoViewModel(repo: repo, client: client)
        }
```

with:

```swift
        let existingByID = Dictionary(uniqueKeysWithValues: repos.map { ($0.id, $0) })
        repos = deduped.map { repo in
            if let existing = existingByID[repo.id] {
                return existing
            }
            let vm = RepoViewModel(repo: repo, client: client)
            vm.autoRebaseOnRejectedPush = autoRebaseRepoIDs.contains(repo.id)
            return vm
        }
```

- [ ] **Step 3: Add the flag, the notice, and the push branch to `RepoViewModel`**

In `Sources/RepoDeck/ViewModels/RepoViewModel.swift`:

After the `actionError` declaration (line 31):

```swift
    /// Per-repo policy seeded from `AppModel.autoRebaseRepoIDs` (the
    /// persisted source of truth): when true, `push()` recovers from a
    /// non-fast-forward rejection by rebasing onto upstream and retrying
    /// once.
    var autoRebaseOnRejectedPush = false
    /// Info-level counterpart to `actionError`: set when an action succeeded
    /// but did something worth surfacing (an auto-rebase before push).
    /// Cleared at the start of the next action and on manual dismiss.
    /// Rendered by `NoticeBanner` in `RepoDetailView`.
    var actionNotice: String?
```

Replace `push()` (lines 224-228):

```swift
    /// Pushes local commits upstream. The log is unchanged by a push, but
    /// refreshing status anyway picks up the new ahead/behind counts.
    func push() async {
        await performAction { try await self.client.push(in: self.repo.path) }
    }
```

with:

```swift
    /// Pushes local commits upstream, refreshing status for the new
    /// ahead/behind counts. With `autoRebaseOnRejectedPush` set, a
    /// non-fast-forward rejection triggers `git pull --rebase --autostash`
    /// and a single retry — and since that can pull new commits in, the log
    /// is refreshed too in that mode.
    func push() async {
        if autoRebaseOnRejectedPush {
            await performAction(refreshingLog: true) {
                if try await self.client.pushWithAutoRebase(in: self.repo.path) == .rebasedAndPushed {
                    self.actionNotice = "Push rejected — rebased onto \(self.status?.upstream ?? "remote") and pushed"
                }
            }
        } else {
            await performAction { try await self.client.push(in: self.repo.path) }
        }
    }
```

In `performAction` (line 240), clear the notice at the start of every action — after `defer { isBusy = false }` (line 243):

```swift
        actionNotice = nil
```

In `commit()` (line 200), same clearing — after `defer { isBusy = false }` (line 204):

```swift
        actionNotice = nil
```

- [ ] **Step 4: Build**

Run: `swift build`
Expected: Build complete, no warnings introduced.

- [ ] **Step 5: Commit**

```bash
git add Sources/RepoDeck/ViewModels/AppModel.swift Sources/RepoDeck/ViewModels/RepoViewModel.swift
git commit -m "feat: wire per-repo auto-rebase policy through app models"
```

---

### Task 4: Context-menu toggle and notice banner

**Files:**
- Modify: `Sources/RepoDeck/Views/Sidebar/RepoRowView.swift:78-90`
- Create: `Sources/RepoDeck/Views/Shared/NoticeBanner.swift`
- Modify: `Sources/RepoDeck/Views/Detail/RepoDetailView.swift:18`

**Interfaces:**
- Consumes: `AppModel.autoRebaseRepoIDs`, `AppModel.toggleAutoRebase(_:)`, `RepoViewModel.actionNotice` (Task 3).
- Produces: `NoticeBanner(notice: Binding<String?>)` view; the menu item itself.

- [ ] **Step 1: Add the checkable menu item**

In `Sources/RepoDeck/Views/Sidebar/RepoRowView.swift`, inside `contextMenuContent`, insert between the Pin/Unpin button (ends line 88) and the `Divider()` (line 90). A SwiftUI `Toggle` inside a `contextMenu` renders as a native checkmark menu item on macOS:

```swift
        Toggle("Auto-Rebase on Rejected Push", isOn: Binding(
            get: { model.autoRebaseRepoIDs.contains(vm.id) },
            set: { _ in model.toggleAutoRebase(vm.id) }
        ))
```

- [ ] **Step 2: Create the notice banner**

Create `Sources/RepoDeck/Views/Shared/NoticeBanner.swift`:

```swift
import SwiftUI

/// Dismissible, non-modal informational counterpart to `ErrorBanner`:
/// shown when an action succeeded but did something worth surfacing (e.g.
/// an auto-rebase before push). Same chrome and placement as `ErrorBanner`,
/// accent-tinted instead of red. Collapses to nothing when `notice` is nil.
struct NoticeBanner: View {
    @Binding var notice: String?

    var body: some View {
        if let notice {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.tint)

                Text(notice)
                    .font(.caption)
                    .textSelection(.enabled)

                Spacer(minLength: 8)

                Button {
                    self.notice = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Dismiss")
            }
            .padding(8)
            .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 10)
            .padding(.top, 6)
        }
    }
}
```

- [ ] **Step 3: Mount it in the detail view**

In `Sources/RepoDeck/Views/Detail/RepoDetailView.swift`, after `ErrorBanner(error: $vm.actionError)` (line 18):

```swift
            NoticeBanner(notice: $vm.actionNotice)
```

Also extend the container's doc comment (lines 3-5) first sentence to mention it:

```swift
/// Container for the selected repo's detail pane: an `ErrorBanner` for the
/// most recent action failure, a `NoticeBanner` for info-level outcomes
/// (e.g. auto-rebase before push), a commit box, sync controls (pull/push/
/// fetch), the changes list, and the commit history.
```

- [ ] **Step 4: Build and verify manually**

Run: `swift build`
Expected: Build complete.

Run: `swift run RepoDeck` and verify by hand:
1. Right-click a repo row → "Auto-Rebase on Rejected Push" appears under Pin, unchecked by default; clicking checks it; reopening the menu shows the checkmark.
2. Quit and relaunch — the checkmark persists.
3. (Full end-to-end rejected-push exercise is covered by the Task 2 integration tests; manual UI verification of the banner is optional here and requires a deliberately staged stale clone.)

- [ ] **Step 5: Commit**

```bash
git add Sources/RepoDeck/Views/Sidebar/RepoRowView.swift Sources/RepoDeck/Views/Shared/NoticeBanner.swift Sources/RepoDeck/Views/Detail/RepoDetailView.swift
git commit -m "feat: add auto-rebase context-menu toggle and notice banner"
```

---

### Task 5: Documentation and final verification

**Files:**
- Modify: `README.md:45` (features list), `README.md:57` (right-click list)
- Modify: `CHANGELOG.md:7` (insert Unreleased section above `## [1.2.0]`)

**Interfaces:**
- Consumes: shipped behavior from Tasks 1-4. Produces: user-facing docs only.

- [ ] **Step 1: README features list**

In `README.md`, insert a new bullet after the "Bulk Fetch All / Pull All" bullet (line 45):

```markdown
- **Auto-rebase on rejected push (per repo)** — right-click a repo and enable **Auto-Rebase on Rejected Push**: when a push is rejected because the remote has new commits, RepoDeck runs `git pull --rebase --autostash` and retries the push once, then shows a dismissible notice. A conflicting rebase aborts cleanly back to the pre-rebase state. Off by default for every repo.
```

- [ ] **Step 2: README right-click list**

In `README.md` line 57, replace:

```markdown
Right-click any repo for Pin/Unpin, Reveal in Finder, Open in Terminal, Open in VS Code (shown only if it's installed), Copy Path, or, for a repo that's vanished from disk, Remove.
```

with:

```markdown
Right-click any repo for Pin/Unpin, the per-repo Auto-Rebase on Rejected Push toggle, Reveal in Finder, Open in Terminal, Open in VS Code (shown only if it's installed), Copy Path, or, for a repo that's vanished from disk, Remove.
```

- [ ] **Step 3: CHANGELOG entry**

In `CHANGELOG.md`, insert above the `## [1.2.0] - 2026-07-08` line (line 8):

```markdown
## [Unreleased]

### Added

- Per-repo **Auto-Rebase on Rejected Push** toggle (right-click a repo in the sidebar): when a push is rejected because the remote has new commits, RepoDeck runs `git pull --rebase --autostash` and retries the push once, surfacing a dismissible notice on success. A conflicting rebase is aborted cleanly, leaving the repo exactly as it was.

```

- [ ] **Step 4: Full verification**

Run: `swift build`
Expected: Build complete.

Run: `swift test`
Expected: entire suite PASSES (including the new `GitErrorTests` and `GitClientSyncTests`).

- [ ] **Step 5: Commit**

```bash
git add README.md CHANGELOG.md
git commit -m "docs: document per-repo auto-rebase on rejected push"
```
