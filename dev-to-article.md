I have somewhere around thirty git repositories checked out on my Mac at any given time — side projects, forks, work I forgot to push before closing the laptop. Every few days I'd ask myself the same question: which of these have uncommitted changes? Which ones are behind their remote and need a pull? The honest answer was always "I don't know," because finding out meant opening each folder in an editor just to glance at the Source Control panel — one repo at a time, over and over.

So I built **RepoDeck** — a native macOS dashboard that tracks a set of folders, recursively finds every git repository underneath them, and shows you at a glance which ones need attention.

![RepoDeck dashboard](https://raw.githubusercontent.com/sergio-farfan/repodeck/648ec69/docs/screenshot.png)

---

## Features

- **Multi-repo dashboard** — track any set of folders; RepoDeck recursively discovers every git repo underneath them
- **Live status via FSEvents** — no polling, no timers; the sidebar badge updates the moment a file changes on disk
- **Stage, commit, and sync** — pull, push, and fetch per repo, plus **Fetch All** / **Pull All** across every tracked repo at once
- **History search** by commit message, author, file path, or content (git's pickaxe search)
- **Sidebar filter and pinning** for the repos you touch most often
- **Themes** — System/Light/Dark, custom accent color, fonts, and font size (⌘,)
- **Resizable Changes/History split**, so you can give more room to whichever pane you're using

---

## The Stack

RepoDeck is Swift Package Manager only — there's no `.xcodeproj`, no `.pbxproj` to merge-conflict over. `swift build`, `swift test`, `swift run RepoDeck` are the entire dev loop.

The UI is SwiftUI, state is `@Observable`, and the codebase builds under Swift 6's strict concurrency checking.

The one deliberate architectural choice worth calling out: RepoDeck shells out to the real `git` binary instead of linking libgit2. That's slower per call, but it means every operation inherits the user's actual `~/.gitconfig` — credential helpers, aliases, hooks, SSH config, everything — for free. It's the same reason VS Code's Source Control panel, GitHub Desktop, and `lazygit` all do the same thing: reimplementing what real git already does correctly, and what your credential helper already knows how to do, is a losing trade.

The package builds two targets: `RepoDeckKit` — every bit of git, parsing, and filesystem-watching logic, with no SwiftUI imports — and `RepoDeck`, the app target, which is just views and view models wired to it. Nothing in `RepoDeckKit` touches a window or the screen; every git call and every filesystem event passes through a seam a test can drive directly. That split is why the code below is unit- and integration-testable at all.

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
    parseRenameOrCopy(record, originalPath: originalPath, into: &changes)
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

Every git invocation in the app funnels through a single function: async, deadlock-free, cancellable, and globally bounded. Two rules made that worth centralizing instead of calling `Process` ad hoc wherever a view model needed git.

### The pipe-drain deadlock

Pipes have a fixed OS buffer. Wait for a child process to exit *before* reading its stdout, and if that process writes more output than the pipe can hold, the child blocks writing while you're blocked waiting for it to exit — a real deadlock, and it only shows up once `git status` output gets big enough to fill the pipe. `ProcessRunner` drains stdout and stderr concurrently, in a loop, while the process is still running:

```swift
async let stderrData = drainAll(stderrStream)

var stdoutData = Data()
var truncated = false
for await chunk in stdoutStream {
    stdoutData.append(chunk)
    if let cap = maxOutputBytes, stdoutData.count >= cap {
        truncated = true
        process.terminate()
        break
    }
}
```

Only after both streams are fully drained does it wait for the actual process exit. The output cap lives in the same loop — once it's hit, the process is terminated on the spot rather than left to keep filling a pipe nobody will finish reading.

### `GIT_TERMINAL_PROMPT=0` and a 6-slot semaphore

Every subprocess runs with `GIT_TERMINAL_PROMPT=0` so a missing credential fails fast with a real error instead of git silently hanging on a terminal prompt that will never appear in a GUI app:

```swift
var env = ProcessInfo.processInfo.environment
env["GIT_TERMINAL_PROMPT"] = "0"
env["LC_ALL"] = "C"
```

And because bulk operations (Fetch All, Pull All) can fire dozens of git processes at once, a process-wide counting semaphore caps concurrency at 6:

```swift
static let concurrencyLimit = 6
static let limiter = ConcurrencyLimiter(limit: concurrencyLimit)
```

Every `ProcessRunner.run` call acquires a slot before launching and releases it on every exit path — success, failure, or cancellation.

### Cancellation kills the child, not just the `Task`

Cancelling the surrounding Swift `Task` — closing a repo, navigating away mid-fetch — has to actually kill the git process, not just stop awaiting it and leave it running orphaned in the background:

```swift
} onCancel: {
    kill(pid, SIGTERM)
}
```

`Process` itself isn't `Sendable`, so only the `pid` — captured before entering the cancellation handler — is allowed to cross into that `@Sendable` closure. The drain loops then end naturally once the killed child closes its pipes.

---

## Watching the Filesystem Without Hammering It

RepoDeck doesn't poll. `RepoWatcher` wraps the FSEvents C API directly and emits debounced events on an `AsyncStream`.

### Ignoring `index.lock` churn

Git itself writes and deletes `.git/index.lock` constantly during normal operations — every `git add`, every `git commit` touches it. Without filtering that out, RepoDeck would refresh its own view of a repo's status in response to changes *caused by its own git calls*:

```swift
static func shouldIgnore(_ rawPath: String) -> Bool {
    let components = rawPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    if components.last == "index.lock", components.contains(".git") {
        return true
    }
    for component in components {
        if component.contains(".watchman-cookie") { return true }
        if prunedNames.contains(component) { return true }
    }
    return false
}
```

### A 300ms debounce — no timer hammering your disk

Saving a file, running a build, or checking out a branch can fire dozens of FSEvents callbacks in a fraction of a second. `RepoWatcher` collapses a burst for the same repo into a single emission, 300ms after the last event in the burst — cancel-and-reschedule, not a recurring poll:

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

There's no timer running in the background polling anything. The app is silent until FSEvents says something changed, and even then it waits out the burst before doing a single `git status`.

---

## The Truncation Seam

This is the bug I'm most annoyed I didn't catch sooner, because both halves of it were individually correct — and individually unit tested.

`ProcessRunner`'s output cap protects against a repo with hundreds of thousands of untracked files turning `git status` into an unbounded memory sink: past the cap, it sends `SIGTERM` to the child and returns whatever was read, flagged as truncated. That's correct, and the unit tests for `ProcessRunner` confirmed it.

`GitClient.status` passes a truncated read through to `PorcelainParser`, which drops the trailing partial record and sets `didHitLimit` on the result. Also correct, also unit tested.

Here's the seam: `SIGTERM` makes the process's exit code come back as 15, not 0. And the shared helper that every `GitClient` method funneled through had one guard for all of them:

```swift
guard result.exitCode == 0 else {
    throw GitError(command: commandString(fullArguments), exitCode: result.exitCode, stderr: result.stderr)
}
```

A truncated status never reached `PorcelainParser` at all — it was thrown as a generic `GitError` before the parser ever saw the bytes. Which meant the "Too many changes — showing a partial list" banner in the Changes list, built and unit tested against a `RepoStatus` with `didHitLimit == true`, was **unreachable** in the running app. Every real truncation just looked like git had failed outright.

Nothing caught this in isolation, because nothing in isolation was wrong. `ProcessRunner`'s truncation tests never touched `GitClient`. `PorcelainParser`'s truncation tests fed it pre-truncated bytes directly, never through a real process exit code. The only place the seam existed was the exact path connecting a real `SIGTERM`, a real exit code 15, and that exit-code guard — and that only shows up in an end-to-end pass, not a unit test of either side alone.

The fix was widening one guard: `result.exitCode == 0 || result.outputTruncated`. Only `status` ever passes an output cap, so no other command's real failures get masked. To lock the seam shut for good, the status output cap became an injectable public property (4 MB by default) so a test could shrink it to 64 bytes against a real temporary repo with real files on disk — forcing an actual truncation, actual `SIGTERM`, actual exit 15, without generating megabytes of fixture data:

```swift
var client = GitClient()
client.statusOutputLimit = 64

let status = try await client.status(in: repo)
#expect(status.didHitLimit == true)
```

The lesson stuck: when two components are each individually correct and each individually tested, that says nothing about the seam between them. A whole-codebase review pass is what caught it — not either of the unit suites, which had been green the entire time. If a bug can only exist in the handoff, only a test that exercises that exact handoff will ever find it.

---

## Build & Install

**Easiest:** grab the `.dmg` from the [latest release](https://github.com/sergio-farfan/repodeck/releases/latest), open it, and drag **RepoDeck** onto **Applications**. It's ad-hoc signed, not notarized, so the first launch needs one manual nudge past Gatekeeper — right-click **RepoDeck.app → Open**, or:

```bash
xattr -dr com.apple.quarantine /Applications/RepoDeck.app
```

**From source** — Swift Package Manager only, no Xcode project needed:

```bash
git clone git@github.com:sergio-farfan/repodeck.git
cd repodeck
swift build
swift test
swift run RepoDeck
```

Full build, packaging, and release commands are in the [README](https://github.com/sergio-farfan/repodeck#build-from-source).

---

## Source Code

RepoDeck is on GitHub: [github.com/sergio-farfan/repodeck](https://github.com/sergio-farfan/repodeck).

---

*Built with Swift 6 and SwiftUI on macOS.*
