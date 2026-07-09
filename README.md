<p align="center">
  <img src="https://img.shields.io/badge/macOS-15%2B-000000?style=flat-square&logo=apple&logoColor=white" alt="macOS 15+">
  <img src="https://img.shields.io/badge/swift-6.1%2B-F05138?style=flat-square&logo=swift&logoColor=white" alt="Swift 6.1+">
  <img src="https://img.shields.io/badge/license-MIT-blue?style=flat-square" alt="MIT License">
  <img src="https://img.shields.io/github/v/release/sergio-farfan/repodeck?style=flat-square&label=version" alt="Version">
  <img src="https://img.shields.io/github/downloads/sergio-farfan/repodeck/total?style=flat-square&label=downloads" alt="Downloads">
</p>

# RepoDeck

**Native macOS dashboard for the git status of all your local repositories.**

<p align="center">
  <img src="docs/screenshot.png" alt="RepoDeck — multi-repo git status dashboard" width="800">
</p>

Track a few dozen local git repositories and one question gets hard to answer at a glance: which ones have uncommitted work, and which ones are behind their remote and need a pull? Finding out normally means opening each folder, one at a time, just to check. RepoDeck answers it for every tracked repo at once, in a single native window that stays current as files change on disk — no manual refresh, no per-repo client to open.

## Download

**[Download the latest RepoDeck.dmg →](https://github.com/sergio-farfan/repodeck/releases/latest)**

Open the `.dmg` and drag **RepoDeck** to **Applications**.

<!-- UNSIGNED-NOTE: remove this block once notarized builds ship. -->
> This build is ad-hoc signed (not notarized). On first launch, right-click **RepoDeck.app → Open**, or run `xattr -dr com.apple.quarantine /Applications/RepoDeck.app`.

Prefer to build it yourself? See [Build from source](#build-from-source).

## Why RepoDeck?

**One dashboard instead of one client per repo.** Opening an editor, or a separate git GUI, for each repository just to check its status doesn't scale past a handful of projects. RepoDeck tracks any number of folders, recursively finds every git repository underneath them, and shows all of their statuses — dirty or clean, ahead or behind — in a single sidebar.

**Live, not polled.** RepoDeck doesn't run a timer that periodically shells out to `git status` across every repo. It wraps the FSEvents API directly and refreshes a repo's status the moment something changes on disk, with a short debounce so a burst of file writes collapses into one refresh — no timer hammering your disk.

**Native and lightweight.** The UI is SwiftUI on AppKit, the whole app bundle is roughly 2 MB, and there are zero third-party dependencies — no Electron, no bundled runtime.

**Plays nice with your real git.** RepoDeck shells out to the system `git` binary for every operation instead of linking a git library. That's slower per call, but every command inherits your actual `~/.gitconfig` — credential helpers, aliases, hooks, SSH config — exactly as if you'd typed it yourself.

## Features

- **Folder tracking with recursive repo discovery** — track any number of folders; RepoDeck walks each one recursively (up to 8 levels deep) and finds every git repository underneath, skipping `node_modules`, `Pods`, `DerivedData`, and other noisy directories.
- **Live FSEvents status** — sidebar badges, ahead/behind counts, and the uncommitted-changes indicator update the moment something changes on disk, with no polling.
- **Stage, commit, pull, push, fetch** — stage or unstage individual files, "Stage All", commit with ⌘⏎, and pull/push/fetch the selected repo from the buttons under the commit box.
- **Bulk Fetch All / Pull All** — fetch or pull every tracked repo at once, with a toolbar progress readout and a dismissible summary of any that failed.
- **Sidebar filter + pinning** — filter the list by repo name or branch, and pin the repos you touch most often into their own section above the rest.
- **History search** by commit message, author, file path, or content (git's pickaxe search) — scoped per repo, updating as you type.
- **Resizable Changes/History split** — drag the divider to give more vertical room to whichever pane you're using.
- **Themes** (System/Light/Dark), custom accent color, fonts, and font size (⌘,) — a Settings window covers appearance, accent color, UI and monospace font family, and base text size.

## Usage

Add one or more folders — from the toolbar's **Add Folder…** button, or the empty-state prompt on first launch — and RepoDeck recursively discovers every git repository underneath them and lists them in the sidebar, sorted alphabetically, with pinned repos in a section of their own above the rest. Selecting a repo shows its status: a **Changes** pane (merge conflicts, staged, unstaged, and untracked files, each in its own section) and, below it, a searchable **History** pane. Drag the divider between the two to resize them.

Stage a file from its row, or use **Stage All**; type a commit message and either click **Commit** or press ⌘⏎ while the message field has focus. **Pull**, **Push**, and **Fetch** for the selected repo sit in a row under the commit box, next to an ahead/behind readout and the current upstream. **Fetch All** and **Pull All**, in the toolbar, do the same across every tracked repo at once; a progress bar tracks how many are done, and a dismissible banner reports how many failed.

Each sidebar row carries a change-count badge and, when applicable, an ahead/behind readout (↑/↓). A small orange dot next to the branch name flags uncommitted changes sitting on `main` or `master` specifically — a repo you probably don't want to leave dirty. Right-click any repo for Pin/Unpin, Reveal in Finder, Open in Terminal, Open in VS Code (shown only if it's installed), Copy Path, or, for a repo that's vanished from disk, Remove.

The History search field matches against whichever scope is selected — Message, Author, File, or Content (git's pickaxe search) — and updates as you type.

| Shortcut | Action |
|----------|--------|
| <kbd>⌘</kbd><kbd>⏎</kbd> | Commit, while the message field has focus |
| <kbd>⌘</kbd><kbd>R</kbd> | Refresh — rescan all tracked folders |
| <kbd>⌘</kbd><kbd>,</kbd> | Open Settings — appearance, accent color, fonts, size |

## Build from source

RepoDeck is Swift Package Manager only — there's no `.xcodeproj`, just `Package.swift`.

```bash
git clone git@github.com:sergio-farfan/repodeck.git
cd repodeck
swift build            # compile
swift test             # run the test suite (71 tests)
swift run RepoDeck     # run in dev mode
Scripts/bundle.sh --open   # build and launch the .app bundle (dist/RepoDeck.app)
Scripts/make-dmg.sh        # package the installer DMG (--release publishes a GitHub Release)
```

### Prerequisites

| Requirement | Details |
|-------------|---------|
| **macOS** | 15+ |
| **Xcode / Swift** | Xcode 26, or a Swift 6.1+ toolchain |
| **git** | at `/usr/bin/git` |

## How It Works

Status parsing runs on `git status --porcelain=v2 --branch --untracked-files=all -z`, invoked with `GIT_OPTIONAL_LOCKS=0` so a concurrent git process never blocks it. `PorcelainParser` is a pure function over the raw output — no `Process`, no I/O — so it's unit-tested directly. Porcelain v2's ordinary-change records carry a two-letter `XY` code (index status, worktree status); a file that's staged *and* has further unstaged edits fans out into two rows, one per side of `XY` that isn't a dot. Rename and copy records spend two NUL-delimited tokens on one logical change (the record, then the original path); untracked files are a bare path; unmerged conflicts get their own area rather than going through the staged/unstaged split.

Filesystem watching wraps the FSEvents C API directly rather than polling. Incoming paths are filtered before anything reaches the app — `.git/index.lock` churn (git rewrites it on every `add`/`commit`, which would otherwise make RepoDeck refresh in response to its own git calls), plus `node_modules`, `.build`, and similar noise. A burst of events for the same repo collapses into a single emission 300ms after the last event in the burst — cancel-and-reschedule, not a recurring timer.

Every git invocation funnels through one function, which drains stdout and stderr concurrently while the process is still running (avoiding a pipe-buffer deadlock on large output), enforces a per-call output cap (4 MB by default for `status`, past which the child is sent `SIGTERM` and the partial read comes back flagged as truncated), and acquires a slot from a process-wide, 6-slot counting semaphore before launching — so Fetch All / Pull All firing dozens of git processes at once never overwhelms the machine. Cancelling the surrounding Swift task sends `SIGTERM` to the actual child process, not just the awaiting task.

Every one of those subprocesses is the real system `git` binary at `/usr/bin/git` — RepoDeck doesn't link libgit2 or reimplement any git internals. That's slower per call than an in-process library, but it means every operation inherits the user's actual `~/.gitconfig`: credential helpers, aliases, hooks, SSH config, everything, for free.

## Project Structure

```
RepoDeck/
├── Sources/
│   ├── RepoDeckKit/          # No SwiftUI imports — the whole git/parsing/watching engine
│   │   ├── Models/           # Repo, RepoStatus, Commit — plain value types
│   │   ├── Git/              # GitClient, ProcessRunner, PorcelainParser, LogParser, HistorySearch
│   │   ├── Scanner/          # RepoScanner — recursive repo discovery
│   │   ├── Watch/             # RepoWatcher — FSEvents wrapper
│   │   └── Theme/             # ColorHex — hex string <-> Color conversion
│   └── RepoDeck/              # App target: views and view models wired to RepoDeckKit
│       ├── Theme/             # Theme, ThemeSettings — appearance/accent/font state
│       ├── ViewModels/        # AppModel (tracked folders, scanning), RepoViewModel (per-repo state)
│       ├── Views/             # ContentView, plus Sidebar/, Detail/, Settings/, Shared/
│       └── Resources/         # AppIcon.icns
├── Tests/RepoDeckKitTests/    # Unit and integration tests, real temp git repos, no mocks
├── Scripts/                   # bundle.sh, make-dmg.sh, make-icon.swift, make-iconset.sh, changelog-section.sh
├── Support/                   # Info.plist
└── docs/                      # screenshot.png
```

## Uninstall

```bash
rm -rf /Applications/RepoDeck.app
defaults delete com.sergiofarfan.repodeck
```

## License

[MIT](LICENSE) — Sergio Farfan (sergio.farfan@gmail.com)
