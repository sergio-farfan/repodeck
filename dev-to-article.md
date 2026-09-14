I have somewhere around thirty git repositories checked out on my Mac at any given time — side projects, forks, work I forgot to push before closing the laptop. Every few days I'd ask myself the same question: which of these have uncommitted changes? Which ones are behind their remote and need a pull? The honest answer was always "I don't know," because finding out meant opening each folder in an editor just to glance at the Source Control panel — one repo at a time, over and over.

So I built **RepoDeck** — a native macOS dashboard that tracks a set of folders, recursively finds every git repository underneath them, and shows you at a glance which ones need attention. It now handles branches, worktrees, conflicts, and code reviews too, without losing that overview.

> *Updated September 2026:* **[1.10.1 is out as a stable release](https://github.com/sergio-farfan/repodeck/releases/tag/v1.10.1)**. The feature list and implementation notes below are current. [From Dashboard to Git Client](#from-dashboard-to-git-client) covers the bigger additions — a commit graph, branch and worktree management, a text conflict resolver, GitHub/GitLab reviews, and the safety fixes behind them.
>
> Want to try it right now? **[Download RepoDeck.dmg →](https://github.com/sergio-farfan/repodeck/releases/latest/download/RepoDeck.dmg)** — open it and drag RepoDeck to Applications.

![RepoDeck history graph and repository sidebar](https://raw.githubusercontent.com/sergio-farfan/repodeck/c4bc3418fe4c714c25b2db10c9f85376dc99f3a4/docs/screenshot.png)

---

## Features

- **Multi-repo dashboard** — track folders, discover repositories and their registered worktrees, and filter for changes, conflicts, ahead/behind state, or errors
- **Live status via FSEvents** — filesystem-driven refreshes, including the separate Git metadata used by linked worktrees
- **Stage, commit, and sync** — pull, push, and fetch per repo, plus **Fetch All** / **Pull All** with success, failure, and skipped counts
- **Diff view with hunk staging** — unified file and commit diffs; stage or unstage eligible text hunks, with whole-file alternatives when exact content or metadata cannot be preserved
- **Commit graph and history search** — parent connections, branch/tag labels, current/all-branch views, 100-commit pages, and search by message, author, file path, or content
- **Branches and worktrees** — create, switch, rename, safely delete merged branches, set tracking, and create, open, or safely remove worktrees
- **Text conflict workspace** — base/current/incoming text, an editable result, separate **Save** and **Mark Resolved**, and operation-aware **Continue** / **Abort** controls
- **GitHub and GitLab reviews** — browse PRs/MRs, file changes, discussion, and checks; create requests, comment, approve, merge, and check out a review into its own worktree, using optional `gh` / `glab` integrations
- **Per-repo auto-fetch** — configurable intervals, a capped background lane, and priority for queued interactive work
- **Auto-rebase on rejected push** — opt-in per repo: a rejected push runs `git pull --rebase --autostash` and retries once; conflicts or a retained autostash can still require recovery
- **Undo for pull and auto-rebase** — restore the recorded commit with `git reset --keep`, bound to the original branch and worktree; this is not a backup of arbitrary local files
- **Repo groups, pinning, hiding/restoring repos, and a ⌘K command palette** for getting around a big sidebar fast
- **Stash support**, optional **GitHub PR/CI badges**, and an optional **menu-bar mode**
- **In-window command runner** — shell commands in the repo's directory, bounded live output, and cancellation that cleans up the owned process group; open a terminal for interactive programs
- **Developer tool preferences** — configurable Git/hosting executables, preferred editor and terminal, and per-repository overrides
- **Themes** — System/Light/Dark, custom accent color, fonts, and font size (⌘,)

---

## The Stack

RepoDeck is Swift Package Manager only — there's no `.xcodeproj`, no `.pbxproj` to merge-conflict over. `swift build`, `swift test`, `swift run RepoDeck` are the entire dev loop.

The UI is SwiftUI, state is `@Observable`, and the codebase builds under Swift 6's strict concurrency checking. The current baseline is **macOS 15+ and Swift 6.2+**.

The one deliberate architectural choice worth calling out: RepoDeck shells out to the real `git` binary instead of linking libgit2. That's slower per call, but it keeps ordinary Git configuration, credential helpers, hooks, and SSH setup in play. Machine-parsed commands set their own output options — a display filter or terminal color setting must not change the bytes that end up staged. I want the installed Git to do the Git work, with the app responsible for choosing the right command and explaining the result.

The package now has three main targets: `RepoDeckKit` contains Git execution, parsing, discovery, file watching, and hosting adapters; `RepoDeckCore` contains application and worktree state, scheduling, and refresh coordination; and `RepoDeck` contains the SwiftUI/AppKit presentation. Tests can inject clients, scanners, clocks, preferences, and watcher events without opening a window. That matters for bugs like an older refresh replacing a newer result, or a slow commit clearing a draft I've edited since pressing Commit.

---

## Parsing `git status --porcelain=v2 -z`

Status parsing runs on `git status --porcelain=v2 --branch --untracked-files=all -z` — NUL-separated so filenames with spaces, newlines, or anything else don't need escaping. `PorcelainParser` is a pure function over `Data`, no `Process`, no I/O, which makes it trivial to unit test without ever invoking git.

### The XY fan-out

Porcelain v2's ordinary-change records carry a two-letter `XY` code: `X` is the index status, `Y` is the worktree status. A file that's staged *and* has further unstaged edits is one record, but RepoDeck's UI wants it in two different sections — Staged and Changes. `appendFanOut` does the split:

```swift
private static func appendFanOut(xy: Substring, path: String, originalPath: String?, into changes: inout [FileChange]) {
    let letters = Array(xy)
    guard letters.count == 2 else { return }
    let indexStatus = letters[0]
    let worktreeStatus = letters[1]
    if indexStatus != "." {
        changes.append(FileChange(path: path, originalPath: originalPath, area: .staged, statusLetter: String(indexStatus)))
    }
    if worktreeStatus != "." {
        changes.append(FileChange(path: path, originalPath: originalPath, area: .unstaged, statusLetter: String(worktreeStatus)))
    }
}
```

One record becomes zero, one, or two `FileChange` rows depending on which half of `XY` isn't a dot.

### Renames consume the next token

Rename and copy records (`2 ...`) are the one record kind where a single logical event spans two NUL-delimited tokens: the record itself, then the original path as a separate token immediately after it. The dispatch loop has to know to look ahead and skip an extra slot:

```swift
case "2":
    let originalPath = index + 1 < records.count ? records[index + 1] : nil
    if let originalPath { parseRenameOrCopy(record, originalPath: originalPath, into: &changes) }
    index += originalPath != nil ? 2 : 1
```

Miss that `index += 2` and the parser starts reading the next file's rename-origin path as if it were a new status record — everything after the first rename in the list comes out garbled.

### Untracked files and merge conflicts

Two more record kinds skip the fan-out entirely. Untracked files (`?` records) are just the path after a fixed two-character prefix:

```swift
private static func parseUntracked(_ record: String, into changes: inout [FileChange]) {
    guard record.count > 2 else { return }
    let path = String(record.dropFirst(2)) // drop "? "
    changes.append(FileChange(path: path, area: .untracked, statusLetter: "U"))
}
```

Unmerged conflicts (`u` records, left behind by a failed merge or rebase) carry their own two-character conflict code and go straight into a dedicated `.unmerged` area rather than through the staged/unstaged split — a conflicted file isn't meaningfully "staged," it's blocking, and the UI treats it that way.

---

## ProcessRunner: One Subprocess Primitive for Everything

Git and hosting commands share one subprocess runner, with async entry points, bounded output, cancellation, and a global concurrency limit. The command pane uses the same machinery. Version 1.10.1 keeps the original reason for centralizing it, but the implementation now owns a POSIX process group for each job.

### The pipe-drain deadlock

Pipes have a fixed OS buffer. Wait for a child process to exit *before* reading its stdout, and if that process writes more output than the pipe can hold, the child blocks writing while you're blocked waiting for it to exit — a real deadlock, and it only shows up once the output gets big enough.

The current worker uses nonblocking file descriptors and services both output streams while the child is running. These two calls sit in the same loop as cancellation, timeout, stdin, and exit handling:

```swift
readOutput(&outputFD, stream: .stdout, decoder: &outDecoder, data: &stdout)
readOutput(&errorFD, stream: .stderr, decoder: &errDecoder, data: &stderr)
```

The combined stdout/stderr budget defaults to **16 MiB**, with smaller limits where a caller needs them. Exceeding the budget starts process-group shutdown. Pipe draining is bounded during shutdown too: a descendant holding an inherited pipe open must not turn a short timeout into a long wait. The blocking `poll`/exit-handling work runs off Swift's cooperative executor.

### `GIT_TERMINAL_PROMPT=0` and a 6-slot semaphore

The runner sets Git's terminal-prompt behavior and locale before applying any explicit caller overrides:

```swift
var env = ProcessInfo.processInfo.environment
env["GIT_TERMINAL_PROMPT"] = "0"
env["LC_ALL"] = "C"
```

That prevents Git from waiting on its own username/password terminal prompt in a GUI operation. It doesn't make every external credential helper or hook noninteractive, so timeouts and useful errors still matter.

Bulk operations can fire dozens of commands at once, so a process-wide limiter caps concurrency at 6:

```swift
static let concurrencyLimit = 6
static let limiter = ConcurrencyLimiter(limit: concurrencyLimit)
```

Background work can hold at most 4 of those slots; queued interactive work has priority. Acquisition itself is cancellable, cancellation is checked again before launch, and every acquired slot is released on success, failure, or cancellation. A running background job still uses resources — this is scheduling priority, not a promise that background work has zero cost.

### Cancellation owns the whole job

Cancelling a Swift `Task` has to stop the command's work, not just stop awaiting its result. Killing only the parent process is insufficient when a child has inherited the output pipes. The runner creates a separate process group at launch, then starts shutdown with:

```swift
func beginStopping() {
    guard stoppingAt == nil else { return }
    stoppingAt = .now
    kill(-pid, SIGTERM)
    closeFD(&inputFD)
}
```

The negative PID targets the owned process group. Shutdown escalates to `SIGKILL` after 500 ms and closes remaining output pipes after one second; the leader is reaped before the job returns. A command's background children belong to that command's lifetime, so the command pane isn't a daemon launcher.

There's one more lifetime to keep straight: cancelling a stream consumer can end iteration before process cleanup finishes. The streaming handle exposes `waitForCompletion()`, and the command pane holds its repository coordination lock until cleanup is done. A stopped pane must not let the next Git mutation overlap a job that's still exiting.

---

## Watching the Filesystem Without Hammering It

Local status refreshes are driven by FSEvents rather than a polling loop. `RepoWatcher` wraps the C API and emits debounced events on an `AsyncStream`. Optional auto-fetch and hosting refreshes are separate scheduled work; “event-driven status” doesn't mean the entire app has no timers.

### Map the repository before filtering the path

Git writes and removes `index.lock` during index updates. Ignoring that lock-file churn avoids unnecessary refreshes, while the actual index and ref changes still matter. The watcher also ignores temporary watchman-cookie events.

The less obvious part is *where* filtering happens. An absolute path can contain a folder named `vendor` or `target` above a perfectly valid repository. Dropping the whole event because one component looks like a dependency directory makes that repository silently stop refreshing.

For a known repository, the watcher first computes a relative path:

```swift
let relative = String(path.dropFirst(repo.key.count))
guard !Self.shouldIgnore(relative, forKnownRepo: true) else { continue }
```

The filter only uses dependency/build-directory pruning for discovery paths, not changes inside a known repository:

```swift
for component in components {
    if component.contains(".watchman-cookie") { return true }
    if !forKnownRepo && prunedNames.contains(component) { return true }
}
```

Linked worktrees need another mapping: their Git directory and shared common directory can live outside the checkout. Those metadata paths are watched too, and a shared change can refresh every affected worktree. If FSEvents reports dropped events, the app schedules repository refreshes and folder discovery instead of assuming its current snapshot is complete.

### A 300ms debounce — no timer hammering your disk

Saving a file, running a build, or checking out a branch can fire dozens of callbacks in a fraction of a second. A burst for the same repo collapses into a single emission about 300ms after the last event — cancel-and-reschedule, not a recurring status poll:

```swift
private func schedule(_ event: WatchEvent, key: String) {
    debounce[key]?.cancel()
    let item = DispatchWorkItem { [weak self] in
        guard let self else { return }
        self.debounce[key] = nil
        guard !self.stopped else { return }
        self.continuation.yield(event)
    }
    debounce[key] = item
    queue.asyncAfter(deadline: .now() + Self.debounceInterval, execute: item)
}
```

The state layer then coalesces rescans and rejects obsolete results. Relevant external Git changes also refresh history, stashes, open diffs, and review context — keeping a sidebar count current isn't enough if the open workspace still describes the old branch.

---

## The Truncation Seam

This is the bug I'm most annoyed I didn't catch sooner, because both halves of it were individually correct — and individually unit tested.

The original `ProcessRunner` output cap protected against a repo with hundreds of thousands of untracked files turning `git status` into an unbounded memory sink: past the cap, it stopped the command and returned what had been captured, flagged as truncated. The unit tests for `ProcessRunner` covered that behavior.

`GitClient.status` was supposed to pass a truncated read through to `PorcelainParser`, which drops the trailing partial record and sets `didHitLimit` on the result. The parser behavior was also unit tested.

Here's the seam: stopping the command with `SIGTERM` could produce a signal exit of 15 instead of 0. The shared helper had this guard:

```swift
guard result.exitCode == 0 else {
    throw GitError(command: commandString(fullArguments), exitCode: result.exitCode, stderr: result.stderr)
}
```

When output-limit shutdown produced a nonzero exit, the helper threw a generic `GitError` before `PorcelainParser` saw the bytes. The "Too many changes — showing a partial list" banner, built and unit tested against a `RepoStatus` with `didHitLimit == true`, therefore failed to appear in exactly that case. A usable partial result looked like an ordinary Git failure.

Nothing caught this in isolation, because nothing in isolation was wrong. `ProcessRunner`'s truncation tests never touched `GitClient`. `PorcelainParser`'s truncation tests fed it pre-truncated bytes directly, never through a real process exit code. The only place the seam existed was the exact path connecting output-limit shutdown, a nonzero exit, and that exit-code guard — and that only shows up in an end-to-end pass, not a unit test of either side alone.

The fix was to let explicitly truncated output reach the caller instead of rejecting it solely because shutdown produced a nonzero exit. Status turns it into a partial list; diff operations reject oversized output instead of offering an incomplete patch. Timed-out results are errors. The runner now has a default cap for other commands too, so the truncation flag is part of the caller's contract, not a general sign of success.

The status cap remains injectable (**4 MB** by default). The integration test creates twenty untracked files and lowers the cap to 256 bytes — enough for some complete records, but not the whole list:

```swift
var client = GitClient()
client.statusOutputLimit = 256

let status = try await client.status(in: repo)
#expect(status.didHitLimit == true)
#expect(status.changes.count >= 1)
#expect(status.changes.count < 20)
```

The lesson stuck: when two components are each individually correct and each individually tested, that says nothing about the seam between them. A whole-codebase review pass is what caught it — not either of the unit suites, which had been green the entire time. If a bug can only exist in the handoff, only a test that exercises that exact handoff will ever find it.

---

## From Dashboard to Git Client

The early releases filled in the everyday gaps: per-repo auto-fetch, groups, a ⌘K palette, opt-in auto-rebase, undo, stashes, PR/CI badges, a menu-bar mode, diffs, and hunk staging. Later came the sidebar identity footer and hiding repositories without deleting their folders. **1.10.1** takes the next step: I can move from noticing a repository needs attention to working through its branch, conflict, or review in the same app.

### History, branches, and worktrees

History now includes a commit graph with parent connections and branch/tag decorations, current/all-branch views, and 100-commit pagination. Branch and worktree management sit alongside it. Discovery asks Git for its registered worktrees, so a linked sibling outside the folder I originally added can still appear in the dashboard.

A review checkout gets its own worktree, leaving the current checkout's files in place. Safe removal checks ignored and untracked files too — a clean-looking Git status must not be taken as permission to discard a local `.env` file. Selection, drafts, and review context belong to each worktree instead of whichever view happens to be mounted.

### Conflicts and code review

The conflict workspace shows base, current, and incoming text with an editable result. **Save** and **Mark Resolved** are separate actions, and both check whether the file or index changed externally. Binary files, unsupported encodings, submodules, and complex conflicts use an external editor/terminal workflow instead of pretending everything is editable text.

GitHub and GitLab reviews use the optional `gh` and `glab` CLIs. Public and self-hosted destinations are represented explicitly; the preview identifies the account, repository, branches, and action before a write. Review lists, descriptions, changed files, discussion, checks, request creation, comments, approvals, and merge are available according to provider capabilities and server permissions. GitHub supports formal change-request reviews; GitLab currently offers comments and approvals for that part of the workflow.

A review can change while it's open. Approving or merging therefore rechecks the reviewed head. A failed write preserves the draft, and uncertain create/comment responses are reconciled before retrying, using the same operation identifier. Local Git workflows still work without either hosting CLI installed.

### The safety work behind the buttons

A hunk-staging button is only useful if it stages exactly the bytes I selected. Partial operations now require lossless UTF-8 and supported file metadata, disable text conversion/external diff helpers/color, and revalidate the displayed diff before writing. Unsupported encodings, symlinks, submodules, renames, or mode changes get a visible whole-file alternative. Selected filenames are literal, so `literal[1].txt` doesn't accidentally select `literal1.txt` too.

Stash selections follow object IDs instead of trusting an old row number. Undo verifies the original worktree, branch, and expected commit. Mutations that share Git metadata are coordinated, and their previews are checked again after waiting for capacity. External Git programs don't participate in that coordination, so I don't describe this as an atomic transaction against every other process on the machine.

The stable release also includes safer icon-resource lookup: missing resources no longer invoke the fatal SwiftPM accessor during launch. Seven fixture scenarios cover packaged apps, executable-adjacent bundles, and absent resources. For the exact released source, [native Apple silicon and Intel CI](https://github.com/sergio-farfan/repodeck/actions/runs/34799832600) each passed **338 tests across 25 suites**, alongside build and packaging checks.

That still leaves work to validate on real setups: clean-machine installation and first launch, the full VoiceOver/appearance matrix, and live GitHub/GitLab writes across permissions and hosting configurations. Those limits are recorded in the [release notes](https://github.com/sergio-farfan/repodeck/releases/tag/v1.10.1). Interactive rebase editing, inline threaded-review editing, issue tracking, and Windows/Linux ports remain future work.

The full per-release detail is in the [changelog](https://github.com/sergio-farfan/repodeck/blob/main/CHANGELOG.md), and the README carries a [release history and roadmap](https://github.com/sergio-farfan/repodeck#releases--roadmap).

---

## Build & Install

**Easiest:** **[download RepoDeck.dmg directly](https://github.com/sergio-farfan/repodeck/releases/latest/download/RepoDeck.dmg)** (or browse the [latest release](https://github.com/sergio-farfan/repodeck/releases/latest)), open it, and drag **RepoDeck** onto **Applications**. The installer is universal for **Apple silicon and Intel**, and requires **macOS 15 or later**.

RepoDeck is **ad-hoc signed and not notarized**. After verifying the download's SHA-256 against the release checksum and attempting to open it, you may need **System Settings → Privacy & Security → Open Anyway**. See [Apple's first-launch instructions](https://support.apple.com/en-lamr/102445); managed Macs may have additional restrictions. This is the standard distribution — Developer ID signing and notarization are optional future improvements.

**From source** — Swift 6.2 or newer, Swift Package Manager, no Xcode project needed:

```bash
git clone https://github.com/sergio-farfan/repodeck.git
cd repodeck
swift build
swift test
swift run RepoDeck
```

Install and authenticate `gh` or `glab` only if you want the corresponding hosting integration. Full build, packaging, and release commands are in the [README](https://github.com/sergio-farfan/repodeck#build-from-source).

---

## Source Code

RepoDeck is on GitHub: [github.com/sergio-farfan/repodeck](https://github.com/sergio-farfan/repodeck).

---

*Built with Swift 6 and SwiftUI on macOS.*
