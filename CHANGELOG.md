# Changelog

All notable changes to RepoDeck will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.7.0] - 2026-07-15

### Added

- **Hunk staging from the diff view** — the diff inspector is no longer read-only: each hunk in an unstaged file's diff gets a + button to stage just that hunk into the index, and each hunk in a staged file's diff gets a − button to unstage it, leaving the file's other hunks untouched. The diff reloads after every action, so a staged hunk disappears from the unstaged side (and vice versa); a hunk that no longer applies because the file changed underneath surfaces the normal error banner. Commit diffs remain read-only, and untracked or conflicted files keep their whole-file controls. This completes the diff feature introduced in 1.5.0.

## [1.6.0] - 2026-07-15

### Added

- **In-window command runner** — a per-repo command pane docked under the detail view: toggle it with the terminal button in the sync bar, or right-click a repo → **Open Command Runner** (the existing **Open in Terminal** still opens Terminal.app). Commands run via your login shell in the repo's directory, with output streamed live in the app's monospace font and theme; ⏎ or **Run** executes, **Stop** terminates a running command, and ↑/↓ recall history. Each repo keeps its own bounded scrollback, and the pane's height is draggable and remembered. Not a terminal emulator — commands run to completion without a TTY (no `vim`/`htop`/interactive programs; stdin reads get EOF; **Stop** terminates the shell, so processes it already spawned may keep running) and ANSI colors are stripped to clean text.

## [1.5.0] - 2026-07-14

### Added

- **Read-only diff view** — right-click any changed file (staged, unstaged, or untracked) or any commit in History and choose **View Diff** to open a side inspector with a unified diff: per-file headers (renames shown as `old → new`), hunk headers, a two-column old/new line-number gutter, and green/red tinted added and removed lines. Binary files are labeled rather than rendered; a conflicted file explains it must be resolved first; an over-large diff is capped rather than freezing the app. The inspector closes with its ✕ button and clears when you switch repos. Double-click still opens the file in TextEdit. Read-only in this release — staging individual hunks from the diff view is coming next.

## [1.4.0] - 2026-07-14

### Added

- **Undo for pull and auto-rebase push** — RepoDeck snapshots HEAD (as a `refs/repodeck/undo/*` ref, so it survives restarts and `git gc`) before every pull and before the rebase-and-retry of an auto-rebase push. An Undo button appears in the sync bar; restoring uses `git reset --keep`, which preserves uncommitted work and refuses rather than clobbering local edits. If the repo has moved on since the operation, Undo refuses with a clear error. One level, per repo; remote state is never touched.
- **Stash support** — a Stashes section at the bottom of the Changes list shows each stash with a relative date; right-click to Apply, Pop, or Drop (Drop asks for confirmation). A Stash button in the sync bar stashes all current changes, untracked files included.
- **GitHub PR/CI badges** — with the GitHub CLI (`gh`) installed and authenticated, the sync bar shows the current branch's open PR (number, draft marker) with a CI rollup dot (green passing / red failing / amber pending / hollow when no checks); click to open the PR. Read-only, refreshed at most every 5 minutes and immediately after a push; invisible when `gh` is missing. Settings ▸ Integrations reports what RepoDeck found.
- **Menu-bar mode** — Settings ▸ General ▸ "Show menu bar icon" adds a menu-bar panel: repo summary, pinned-then-dirtiest repo list (click a row to open it in the main window), and Fetch All / Pull All / Quit. Off by default; the main window stays primary.

### Changed

- Stash-changing actions keep the repo marked busy until the stash list has re-synced, so rapid follow-up actions can never act on stale stash indices.

## [1.3.0] - 2026-07-14

### Added

- Per-repo **Auto-Rebase on Rejected Push** toggle (right-click a repo in the sidebar): when a push is rejected because the remote has new commits, RepoDeck runs `git pull --rebase --autostash` and retries the push once, surfacing a dismissible notice on success. A conflicting rebase is aborted cleanly, leaving the repo exactly as it was.
- **Repository Settings sheet** — right-click a repo, "Repository Settings…": auto-rebase on rejected push, auto-fetch interval, and group assignment. Changes apply immediately.
- **Per-repo auto-fetch** — set an interval (5/15/30/60 minutes) per repo; RepoDeck fetches quietly in the background and updates ahead/behind counts. Background fetches never raise error banners (going offline stays quiet) and run in a capped background lane (4 of 6 subprocess slots) so they never delay user-initiated actions, which jump the queue.
- **Repo groups** — assign repos to named sidebar groups via the settings sheet or right-click → Move to Group. Sidebar order: Pinned, then one section per group (alphabetical), then ungrouped Repositories; the filter applies within sections.
- **Command palette (⌘K)** — jump to any repo or run Fetch All / Pull All / Refresh Repositories and selected-repo Pull / Push / Fetch / Reveal in Finder / Open in Terminal from the keyboard, ranked prefix > word-boundary > substring.

### Changed

- Changed files now always open in TextEdit (both double-click and the "Open in Editor" context menu item). Binary or deleted files no longer offer an open action.
- Double-clicking a file now flashes the row with the accent color as open-acknowledgment feedback.
- Network git operations now time out instead of hanging forever: fetch after 90 seconds, pull/push after 5 minutes, reported as a normal per-repo error.
- Per-repo settings (pin, auto-rebase, auto-fetch, group) are consolidated into a single store; existing pins and auto-rebase toggles migrate automatically on first launch.

## [1.2.0] - 2026-07-08

### Added

- DMG installer with a styled disk image: Finder icon-view layout, background artwork, and an `/Applications` drag target (`Scripts/make-dmg.sh`).
- GitHub Release distribution: checksummed (`.sha256`) `.dmg`, published via `gh release create`/`upload`.
- Installation docs.
- dev.to article source.

### Changed

- App icon redesigned as a purple commit graph on black.

## [1.1.0] - 2026-07-08

### Added

- App icon.
- Theme system (System/Light/Dark, accent color, fonts, size) with a Settings window (⌘,).
- Draggable Changes/History splitter.
- History search by message, author, path, and content.

### Fixed

- Settings-window theming.
- Stale search errors.

## [1.0.0] - 2026-07-08

### Added

- Multi-repo dashboard.
- Folder tracking with recursive repo discovery.
- Live FSEvents status.
- Stage, commit, and sync (fetch/pull/push).
- Bulk Fetch All / Pull All.
- Sidebar filter and pinning.
- History list.

[1.3.0]: https://github.com/sergio-farfan/repodeck/releases/tag/v1.3.0
[1.2.0]: https://github.com/sergio-farfan/repodeck/releases/tag/v1.2.0
[1.1.0]: https://github.com/sergio-farfan/repodeck/releases/tag/v1.1.0
[1.0.0]: https://github.com/sergio-farfan/repodeck/releases/tag/v1.0.0
