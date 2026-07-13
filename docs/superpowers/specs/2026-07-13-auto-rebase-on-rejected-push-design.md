# Auto-rebase on rejected push (per-repo) — Design

- **Date:** 2026-07-13
- **Author:** Sergio Farfan
- **Status:** Approved for planning

## Context

RepoDeck's Push action is a bare `git push` (`GitClient.push(in:)`). When the remote
has commits the local copy doesn't, the push is rejected as non-fast-forward and the
raw git error lands in the error banner; the user has to drop to a terminal and run
`git pull --rebase` by hand. For repos with a no-branch, commit-straight-to-main
workflow, a rebase-and-retry is the fix essentially every time.

## Goals

- A per-repo, opt-in toggle: when a push is rejected as non-fast-forward,
  automatically `git pull --rebase --autostash`, then retry the push once.
- Default behavior (toggle off) is byte-for-byte unchanged for every repo.
- The repo is never left mid-rebase: on conflict, abort and restore prior state.
- Successful auto-rebase is surfaced to the user (history was rewritten silently
  otherwise).
- The new git logic is covered by offline integration tests.

## Non-goals (out of scope)

- Per-repo pull-style override (rebase vs merge for the Pull button).
- Push-after-commit / combined commit-and-push action.
- Bulk push (does not exist today; not added).
- Any conflict-resolution UI.
- A per-repo settings sheet (single toggle lives in the context menu).
- Re-keying persisted settings when a repo folder moves (shared, pre-existing
  limitation of the path-keyed `pinnedRepoIDs` pattern).

## Behavior

- New checkable context-menu item on each repo row: **"Auto-rebase on rejected
  push"**, grouped with Pin/Unpin. Off by default for all repos.
- Toggle **off**: Push calls `GitClient.push(in:)` exactly as today.
- Toggle **on**: Push calls the new composite `GitClient.pushWithAutoRebase(in:)`:
  1. Run `git push`.
  2. If it succeeds → done (outcome `.pushed`; silent, same as today).
  3. If it fails and the error **is not** a non-fast-forward rejection → rethrow
     unchanged; no rebase is attempted.
  4. If it **is** a rejection → run `git pull --rebase --autostash`.
  5. If the rebase completes → run `git push` again (exactly one retry). Success →
     outcome `.rebasedAndPushed`; failure → throw that push error.
  6. If the rebase conflicts or fails → attempt `git rebase --abort`, ignoring its
     result (it fails harmlessly when no rebase is in progress, e.g. when the pull
     never started one), then throw a `GitError` carrying the rebase stderr.

### Rejection classification

`GitError` gains a computed property `isNonFastForwardPushRejection`: true when
stderr contains `[rejected]` **and** (`non-fast-forward` **or** `fetch first`).
This matching is locale-stable because `ProcessRunner` already forces `LC_ALL=C`
on every child process. `stale info` (a `--force-with-lease` artifact) is
deliberately excluded — RepoDeck never uses force pushes.

### Feedback

- `.rebasedAndPushed` → dismissible **info banner** on the repo detail view:
  "Push rejected — rebased onto `<upstream>` and pushed" (upstream from
  `RepoStatus.upstream`; "remote" when unknown).
- `.pushed` → silent (unchanged).
- All failures → existing error banner (`actionError` / `GitError` path), showing
  the failing command and its stderr.

### Known edge: autostash pop conflict

If the rebase succeeds but re-applying the autostash conflicts, git completes the
pull (changes are kept safe — applied with conflict markers or retained in the
stash) and the retry push proceeds with the rebased commits. The subsequent status
refresh shows the unmerged/dirty files. No special-casing; pinned down by a test
(including empirically confirming the pull's exit code in that scenario).

## Architecture

Follows the existing layering: View → view model (app target) → `GitClient` →
`ProcessRunner` (kit). Policy **storage** lives in the app layer; policy
**execution** lives in the kit.

### RepoDeckKit changes

`Sources/RepoDeckKit/Git/GitClient.swift`
- `public enum PushOutcome: Sendable { case pushed, rebasedAndPushed }`
- `public func pushWithAutoRebase(in repo: URL) async throws -> PushOutcome` —
  the composite above. Internal steps reuse the private `run`/`runVoid` helpers:
  `pull --rebase --autostash`, `rebase --abort`.

`Sources/RepoDeckKit/Git/GitError.swift`
- `public var isNonFastForwardPushRejection: Bool` (pure string predicate).

### RepoDeck app changes

`ViewModels/AppModel.swift`
- `var autoRebaseRepoIDs: Set<String>` persisted to `UserDefaults` under key
  `"autoRebaseRepoIDs"` — a mirror of `pinnedRepoIDs` (load in `init`, save on
  mutation, keyed by repo path).
- `func toggleAutoRebase(_ id: String)` — flips the set, persists, and updates the
  live `RepoViewModel`'s flag.
- `rescan()` seeds `autoRebaseOnRejectedPush` on newly created view models
  (existing VMs are already reused by id and keep their state).

`ViewModels/RepoViewModel.swift`
- `var autoRebaseOnRejectedPush: Bool = false` (in-memory; source of truth is
  `AppModel`'s persisted set).
- `var actionNotice: String?` — info-level counterpart to `actionError`; cleared
  at the start of the next action and on manual dismiss.
- `push()` branches: flag off → `client.push` (unchanged); flag on →
  `client.pushWithAutoRebase`, mapping `.rebasedAndPushed` to `actionNotice`.

`Views/Sidebar/RepoRowView.swift`
- Context menu: checkable "Auto-rebase on rejected push" item (checkmark when
  enabled), placed with Pin/Unpin, calling `model.toggleAutoRebase(vm.id)`.

`Views/Shared/NoticeBanner.swift` (new)
- Sibling view to `ErrorBanner.swift` rather than a generalization of it:
  an **info** variant (accent-tinted) mirroring `ErrorBanner`'s chrome, bound
  to `actionNotice`. `ErrorBanner` itself is unchanged. Mounted in the same
  top slot of `RepoDetailView`, alongside the existing error banner.

## Data flow

Right-click toggle → `AppModel.toggleAutoRebase` → persists set + updates VM flag
→ user clicks Push → `RepoViewModel.push()` → `performAction` (busy-gating,
error capture, status refresh — unchanged) → `client.pushWithAutoRebase` →
outcome mapped to notice / error → banner renders; status refresh shows the new
ahead/behind.

## Persistence

- Key: `"autoRebaseRepoIDs"`, `[String]` of repo paths in `UserDefaults.standard`
  (same mechanics and caveats as `"pinnedRepoIDs"`; `@AppStorage` is not usable
  inside `@Observable` classes).
- Absent key → empty set → feature off everywhere: no migration needed.

## Testing

All in `Tests/RepoDeckKitTests`, fully offline, using a **local bare repo as the
remote**: `git init --bare` + two clones that diverge. New helper alongside
`withTempRepo`.

1. **Classification:** push from a stale clone → thrown `GitError` has
   `isNonFastForwardPushRejection == true`; unit-test the predicate against
   canned stderr variants (`fetch first`, `non-fast-forward`, auth-ish noise →
   false).
2. **Happy path:** remote ahead with non-conflicting commit →
   `pushWithAutoRebase` returns `.rebasedAndPushed`; remote log contains both
   commits; local worktree clean.
3. **No-op path:** remote not ahead → returns `.pushed`, exactly one push, no
   rebase side effects.
4. **Conflict path:** remote and local edit the same line → throws; no
   `.git/rebase-merge`/`.git/rebase-apply` left; local HEAD is the pre-rebase
   commit.
5. **Non-rejection failure:** push with no valid remote → original error
   rethrown; repo untouched (no rebase attempted).
6. **Autostash:** dirty worktree + remote ahead → succeeds and the uncommitted
   change survives; separately, document/confirm exit-code behavior when the
   autostash pop itself conflicts.

App-layer changes stay thin (one branch in `push()`, a set-toggle mirroring pins)
— consistent with the existing untested-app-target split.

## Documentation updates

- `README.md`: add the toggle to the features list and to the documented
  right-click menu items.
- `CHANGELOG.md`: entry under the next version (current released: 1.2.0).
