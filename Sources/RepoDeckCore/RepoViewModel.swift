import Foundation
import Observation
import RepoDeckKit

/// One-level undo state for the last `pull()` or auto-rebase `push()`:
/// the pre-operation `UndoSnapshot` plus the HEAD the operation landed on
/// (`postOpHead`), so `undoLastSync()` can guard against the repo having
/// moved on again before restoring.
public struct UndoRecord {
    public let snapshot: UndoSnapshot
    public let postOpHead: String
    /// e.g. "pull" / "auto-rebase push" — used in the Undo button's label.
    public let description: String
}

/// What `showDiff(_:)` is currently (or was last) loading a diff for; a
/// non-nil value drives the `.inspector` open via `isDiffPresented`.
public enum DiffTarget: Equatable {
    case workingFile(FileChange)   // area decides staged/unstaged/untracked
    case commit(Commit)
}

/// Which direction (if any) a per-hunk button in `DiffView` should offer,
/// driven by `RepoViewModel.diffHunkAction`.
public enum HunkAction {
    case stage
    case unstage
}

/// View model for a single tracked repo: owns its live status and the
/// coalesced refresh that keeps it current.
@MainActor
@Observable
public final class RepoViewModel: @MainActor Identifiable {
    public let repo: Repo
    public var client: GitClient
    @ObservationIgnored private let clock: @Sendable () -> Date
    @ObservationIgnored private let reviewLoader: (@Sendable (String, URL, String) async throws -> PullRequestInfo?)?
    public private(set) var context: RepositoryContext?
    public private(set) var operationState: RepositoryOperationState = .normal
    public var selectedSection: RepositorySection = .changes
    public let workspace = RepositoryWorkspaceModel()
    public var refreshRevision: Int = 0
    public var hostingError: String?

    public var status: RepoStatus?
    public var statusError: String?
    public var isMissing = false
    /// Draft commit message bound to `CommitBoxView`'s text field.
    public var commitMessage: String = ""
    /// Populated by `refreshLog()`; rendered by `HistoryListView`.
    public var commits: [Commit] = []
    /// Populated by `refreshStashes()`; rendered by `StashSection` at the
    /// bottom of `ChangesListView`.
    public var stashes: [StashEntry] = []
    /// Effective git identity shown by the sidebar footer. Passive like
    /// `refreshStashes`: stale beats blank.
    public var gitIdentity: GitIdentity?
    /// Free-text history search bound to `HistoryListView`'s search field.
    /// Trimmed empty (the default) means "no filter" — `refreshLog()` falls
    /// back to the full `client.log(in:)`.
    public var historyQuery: String = ""
    /// Which axis `historyQuery` is matched against.
    public var historyField: HistorySearchField = .message
    /// True while a stage/unstage/commit/sync action is running; `refreshStatus`
    /// never touches this — refresh is a passive, always-allowed operation.
    public var isBusy = false
    /// Set by a failed stage/unstage/commit/sync action; cleared on the next
    /// successful action. Rendered by `ErrorBanner` in `RepoDetailView`.
    public var actionError: GitError?
    /// Per-repo policy seeded from `AppModel.settings(for:)` (the
    /// persisted source of truth, via `repoSettingsByID`): when true,
    /// `push()` recovers from a non-fast-forward rejection by rebasing onto
    /// upstream and retrying once.
    public var autoRebaseOnRejectedPush = false
    /// Info-level counterpart to `actionError`: set when an action succeeded
    /// but did something worth surfacing (an auto-rebase before push).
    /// Cleared at the start of the next action and on manual dismiss.
    /// Rendered by `NoticeBanner` in `RepoDetailView`.
    public var actionNotice: String?
    /// One-level undo for the last `pull()` or auto-rebase `push()`, if
    /// its snapshot is still live (see `pull()`/`push()` for when it's
    /// written vs. discarded as noise). `undoLastSync()` consumes and
    /// clears it on success; a later sync operation simply replaces it —
    /// `writeUndoSnapshot`'s own pruning handles the superseded ref.
    /// Rendered as an Undo button by `SyncControlsView` whenever non-nil.
    public var undoRecord: UndoRecord?
    /// Set by a failed `autoFetch()`; cleared on the next successful one.
    /// Surfaced nowhere yet — kept for debugging and a future indicator.
    public var lastAutoFetchError: String?
    /// The current branch's open PR + CI rollup, via `gh`. Populated by
    /// `refreshPRInfo(using:)`; nil means "nothing to show" whether that's
    /// because gh is unavailable, there's no open PR, or the last refresh
    /// failed — this is a read-only, entirely optional feature, so every
    /// one of those cases renders identically (no badge). Rendered as a
    /// `PRBadgeView` by `SyncControlsView` only when non-nil.
    public var prInfo: PullRequestInfo?
    /// When `prInfo` was last (successfully or unsuccessfully) refreshed —
    /// the TTL clock `refreshPRInfo(using:)` checks before calling `gh`
    /// again.
    public var prInfoFetchedAt: Date?
    /// The branch `prInfo`/`prInfoFetchedAt` correspond to. The TTL only
    /// applies while the branch is unchanged: a branch switch (external
    /// `git checkout`, etc.) makes any cached `prInfo` *wrong*, not merely
    /// stale, so `refreshPRInfo(using:)` drops it and bypasses the TTL when
    /// this no longer matches `status?.branch`. Without this a branch change
    /// within the TTL window would keep the previous branch's PR badge —
    /// and clicking it would open the wrong PR.
    private var prInfoBranch: String?

    /// The file or commit `showDiff(_:)` is loading/loaded a diff for;
    /// non-nil drives the read-only diff `.inspector` open on
    /// `RepoDetailView` via `isDiffPresented`. Set to nil to dismiss.
    public var diffTarget: DiffTarget?
    /// Rendered result of the most recent `showDiff(_:)` call; consumed by
    /// `DiffView`.
    public var diffFiles: [FileDiff] = []
    /// True while `showDiff(_:)`'s git call is in flight.
    public var isLoadingDiff = false
    /// Set by a failed `showDiff(_:)`; shown inline inside the inspector —
    /// deliberately NOT `actionError`, since a diff load must never disable
    /// the git action buttons or paint `RepoDetailView`'s error banner.
    public var diffError: String?

    /// Binding source for `.inspector(isPresented:)` on `RepoDetailView`:
    /// true whenever `diffTarget` is set. The setter backs the inspector's
    /// own dismiss chrome (its close button/swipe) — SwiftUI writes `false`
    /// there, which this turns into clearing `diffTarget`; it never writes
    /// `true` itself (that only happens via `showDiff(_:)`).
    public var isDiffPresented: Bool {
        get { diffTarget != nil }
        set { if !newValue { diffTarget = nil } }
    }

    /// Which per-hunk button (if any) `DiffView` should render for the
    /// CURRENT `diffTarget`, so it doesn't re-derive the gating rule itself.
    /// Hunk staging only applies to a working-tree file's unstaged or staged
    /// diff — a commit diff is read-only (can't stage a historical hunk),
    /// and untracked/unmerged have no hunks worth a button (untracked stages
    /// whole-file via the existing Changes-list control; unmerged shows the
    /// resolve-conflict message instead of a diff).
    public var diffHunkAction: HunkAction? {
        guard case let .workingFile(change) = diffTarget else { return nil }
        switch change.area {
        case .unstaged: return .stage
        case .staged: return .unstage
        case .untracked, .unmerged: return nil
        }
    }

    /// Whether the in-window command-runner pane (`CommandRunnerView`,
    /// docked at the bottom of `RepoDetailView` via a nested `VerticalSplit`)
    /// is shown for this repo. Toggled by `SyncControlsView`'s toolbar button
    /// and set directly by the sidebar's "Open Command Runner" context-menu
    /// item.
    public var isCommandPaneVisible = false
    /// Accumulated, ANSI-stripped runner output: each command is echoed as
    /// `"$ <cmd>"`, followed by its interleaved stdout/stderr, followed by
    /// `"[exited N]"` when it exits non-zero (or `"[failed to run: ...]"` if
    /// the shell itself couldn't be launched). Capped at
    /// `Self.commandOutputCap` characters — see `appendOutput(_:)`.
    public private(set) var commandOutput: String = ""
    /// Bound to `CommandRunnerView`'s input field.
    public var commandInput: String = ""
    /// True while `runCommand()`'s child process is running. Deliberately
    /// separate from `isBusy` — see `runCommand()`.
    public private(set) var isRunningCommand = false
    /// Commands previously run, most-recent last. `CommandRunnerView` cycles
    /// `commandInput` through this on up/down arrow; the cursor into it is
    /// kept as `@State` in that view, not here.
    public private(set) var commandHistory: [String] = []
    /// The task consuming `runCommand()`'s `ProcessRunner.runStreaming`
    /// stream, so `cancelCommand()` has something to cancel — cancelling it
    /// SIGTERMs the child (see `ProcessRunner.runStreaming`).
    private var commandTask: Task<Void, Never>?
    /// Upper bound on `commandOutput`'s length, in characters. Keeps memory
    /// bounded against a chatty or long-lived command.
    private static let commandOutputCap = 200_000
    /// Trim only once output grows well past the cap (in UTF-8 bytes), so the
    /// O(n) trim runs rarely rather than on every chunk once at steady state.
    private static let commandOutputHighWater = 300_000

    /// Coalescing pair: only one `git status` runs per repo at a time. A call
    /// that arrives mid-refresh is folded into a single trailing refresh
    /// instead of piling up concurrent invocations.
    private var refreshInFlight = false
    private var refreshQueued = false

    /// Own in-flight guard for `refreshPRInfo(using:)` — deliberately not
    /// `isBusy`/`performAction`: a slow or failed `gh` call must never
    /// disable the git action buttons or paint `actionError`'s banner for
    /// what is an entirely optional, best-effort integration.
    private var prRefreshTask: Task<Void, Never>?
    private var prRequestedBranch: String?
    private var prRefreshGeneration = 0
    /// How long a successful-or-not `prInfo` fetch is considered fresh
    /// before `refreshPRInfo(using:)` will call `gh` again (unless `force`).
    private static let prInfoTTL: TimeInterval = 300

    /// The in-flight debounced/immediate search reschedule, if any.
    /// Cancelled and replaced by every call to `scheduleHistorySearch()` or
    /// `historyFieldChanged()`, so only the most recently requested search
    /// actually runs through this slot.
    private var historySearchTask: Task<Void, Never>?

    /// Monotonic counter bumped at the entry of every `refreshLog()` call.
    /// Each call captures its own value and re-checks it after every await,
    /// so a slower, older refresh can never overwrite a newer one's result
    /// — see `refreshLog()` for the full guarantee. This is what actually
    /// prevents clobbering; `historySearchTask` cancellation is a secondary,
    /// best-effort measure (it can't stop an already-running git subprocess).
    private var historyGeneration = 0

    /// Same guarantee as `historyGeneration`, for `showDiff(_:)`: two rapid
    /// "View Diff" clicks (e.g. file A then file B) each capture their own
    /// generation, and whichever git call resolves last only wins if it's
    /// still the current one — otherwise an older, slower load for A can't
    /// clobber `diffFiles` after a newer load for B already started.
    private var diffGeneration = 0

    public var id: String { repo.id }

    /// True when `status` has at least one change staged for commit.
    public var hasStagedChanges: Bool { status?.changes.contains { $0.area == .staged } ?? false }

    public init(repo: Repo, client: GitClient, clock: @escaping @Sendable () -> Date = { Date() },
                reviewLoader: (@Sendable (String, URL, String) async throws -> PullRequestInfo?)? = nil) {
        self.clock = clock
        self.reviewLoader = reviewLoader
        self.repo = repo
        self.client = client
    }

    public func refreshContext() async {
        context = try? await RepositoryContext.resolve(in: repo.path, gitPath: client.gitPath)
        operationState = context.map { RepositoryOperationState.read(in: $0) } ?? .normal
    }

    public func refreshForExternalChange() async {
        await refreshStatus()
        await refreshContext()
        await refreshLog()
        await refreshStashes()
        if let target = diffTarget { await showDiff(target) }
        refreshRevision += 1
    }

    /// Refreshes `status` from disk. Safe to call from multiple call sites
    /// (rescan, watcher, manual refresh) without racing: if a refresh is
    /// already running, this marks one more trailing refresh and returns.
    public func refreshStatus() async {
        if refreshInFlight {
            refreshQueued = true
            return
        }
        refreshInFlight = true
        defer { refreshInFlight = false }

        repeat {
            refreshQueued = false
            await performRefresh()
        } while refreshQueued
    }

    private func performRefresh() async {
        guard FileManager.default.fileExists(atPath: repo.path.path) else {
            isMissing = true
            status = nil
            return
        }
        isMissing = false
        do {
            status = try await client.status(in: repo.path)
            statusError = nil
        } catch {
            // Stale status beats a blank one; keep whatever we last had.
            statusError = error.localizedDescription
        }
    }

    /// Stages a single change. For renames/copies, `change.path` (the new
    /// path) alone is sufficient — `git add -- <newPath>` stages the pair.
    public func stage(_ change: FileChange) async {
        await performAction(allowInProgress: true) { try await client.stage([change.path], in: repo.path) }
    }

    /// Unstages a single change.
    public func unstage(_ change: FileChange) async {
        var paths = [change.path]
        if change.statusLetter == "R", let original = change.originalPath { paths.append(original) }
        await performAction(allowInProgress: true) { try await client.unstage(paths, in: repo.path) }
    }

    /// Stages everything, tracked and untracked (`git add -A`).
    public func stageAll() async {
        await performAction(allowInProgress: true) { try await client.stageAll(in: repo.path) }
    }

    /// Refreshes `commits` from `git log`, or `git log`'s search-filtered
    /// equivalent when `historyQuery` (trimmed) is non-empty. On failure,
    /// records `actionError` but leaves `commits` untouched — a stale log
    /// beats a blank one.
    ///
    /// This is called from several places that can race each other — the
    /// debounced search (`scheduleHistorySearch()`), the immediate
    /// scope-change refresh (`historyFieldChanged()`), the initial
    /// `.task(id:)` load, and the post-commit/post-pull refreshes in
    /// `commit()`/`performAction()`. `ProcessRunner` cancellation only
    /// SIGTERMs the child process; if it exits 0 before noticing the
    /// signal, a cancelled call still returns a normal, but stale, result.
    /// So every call captures `historyGeneration` at entry and, after the
    /// single await that produces its result, re-checks that it is still
    /// the current generation (and not cancelled) before touching `commits`
    /// or `actionError`. Whichever request is newest when its await
    /// resolves wins; an older, slower one is silently dropped no matter
    /// which one's git process happens to finish last.
    public func refreshLog() async {
        historyGeneration += 1
        let generation = historyGeneration
        do {
            let trimmedQuery = historyQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            let result: [Commit]
            if trimmedQuery.isEmpty {
                result = try await client.log(in: repo.path)
            } else {
                let query = HistorySearchQuery(text: trimmedQuery, field: historyField)
                result = try await client.searchLog(query, in: repo.path)
            }
            guard generation == historyGeneration, !Task.isCancelled else { return }
            commits = result
            // A keystroke-driven search can fail transiently (e.g. an
            // unmatched "[" mid-typing makes --grep a broken regex) and set
            // the banner; once a later refresh succeeds, that stale log/search
            // error is obsolete. Only clear errors from log commands — a
            // failed commit/pull banner must survive a background log refresh.
            if let existing = actionError, existing.command.contains(" log ") {
                actionError = nil
            }
        } catch let error as GitError {
            guard generation == historyGeneration, !Task.isCancelled else { return }
            actionError = error
        } catch {
            guard generation == historyGeneration, !Task.isCancelled else { return }
            actionError = GitError(command: "git", exitCode: -1, stderr: error.localizedDescription)
        }
    }

    /// Refreshes `stashes` from `git stash list`. Passive like
    /// `refreshStatus`: no `isBusy`, no `actionError` banner on failure — a
    /// stale list beats a blank one, so a failure just leaves `stashes`
    /// untouched. Called from `RepoDetailView.task(id:)` alongside
    /// `refreshLog()`, and at the tail of every stash mutation below.
    public func refreshStashes() async {
        stashes = (try? await client.stashList(in: repo.path)) ?? stashes
    }

    /// Refreshes `gitIdentity` from the repo's effective `git config`.
    /// Passive like `refreshStashes`: no `isBusy`, no `actionError` banner —
    /// a stale identity beats a blank one, so a failure leaves it untouched.
    /// Called from `SidebarIdentityFooter.task(id:)` on selection change.
    public func refreshIdentity() async {
        gitIdentity = (try? await client.configuredIdentity(in: repo.path)) ?? gitIdentity
    }

    /// Loads the diff for `target` into `diffFiles`, driving `DiffView`
    /// inside the `.inspector`. Read-only with its own guard — deliberately
    /// NOT routed through `performAction`: a diff load must not disable the
    /// git action buttons (`isBusy`) or paint `actionError`'s banner, so
    /// failures land in `diffError` and are shown inline in the inspector
    /// instead. Setting `diffTarget` up front is what opens the inspector
    /// (via `isDiffPresented`), before the load even starts.
    ///
    /// `.unmerged` is special-cased with no git call at all: a conflicted
    /// file's working-tree diff is combined-diff format (`diff --cc`,
    /// `@@@`), which `DiffParser` returns `[]` for — routing it through
    /// `client.diff` would land on the empty-state "No Changes to Show",
    /// which reads as if the conflict resolved itself. `diffError` carries
    /// an explicit explanation instead.
    ///
    /// Guarded by `diffGeneration` (mirrors `refreshLog()`'s
    /// `historyGeneration`): two rapid "View Diff" clicks each capture their
    /// own generation before the single await below, and the result — the
    /// local `files`/`message`, computed but not yet written to
    /// `diffFiles`/`diffError`/`isLoadingDiff` — is only committed if this
    /// call's generation is still current AND `diffTarget` still matches
    /// what was requested; otherwise a newer request has already superseded
    /// it and this one's result is silently dropped, however late it
    /// resolves.
    public func showDiff(_ target: DiffTarget) async {
        diffGeneration += 1
        let generation = diffGeneration
        diffTarget = target
        isLoadingDiff = true
        diffError = nil
        var files: [FileDiff] = []
        var message: String?
        do {
            switch target {
            case .workingFile(let change):
                switch change.area {
                case .staged:
                    files = try await client.diff(path: change.path, staged: true, in: repo.path).map { [$0] } ?? []
                case .unstaged:
                    files = try await client.diff(path: change.path, staged: false, in: repo.path).map { [$0] } ?? []
                case .untracked:
                    files = try await client.diffUntracked(path: change.path, in: repo.path).map { [$0] } ?? []
                case .unmerged:
                    message = "Conflicted file — resolve the conflict to view its diff."
                }
            case .commit(let commit):
                files = try await client.diffCommit(commit.hash, in: repo.path)
            }
        } catch let error as GitError {
            message = error.stderr.isEmpty ? "git exited \(error.exitCode)" : error.stderr
        } catch {
            message = error.localizedDescription
        }
        guard generation == diffGeneration, diffTarget == target else { return }
        diffFiles = files
        diffError = message
        isLoadingDiff = false
    }

    /// Stages one hunk (from the unstaged working-tree diff shown by
    /// `showDiff`) into the index: `PatchBuilder` builds the patch AS the
    /// unstaged diff represents it (`reverse: false`), and `applyPatch`
    /// applies it plain (`cached: true, reverse: false`) — this IS an index
    /// mutation, so it goes through `performAction` (busy-guard,
    /// `actionError` banner on failure such as "patch does not apply",
    /// status refresh). After the index changes, the diff inspector is
    /// reloaded for the same target so the staged hunk disappears from the
    /// unstaged diff (a now-empty diff shows the empty state) while any
    /// other hunks in the file stay put.
    public func stageHunk(_ hunk: Hunk, in file: FileDiff) async {
        await performAction(allowInProgress: true) {
            try await self.validateDisplayedHunk(hunk, file: file, staged: false)
            let patch = try PatchBuilder.checkedPatch(for: hunk, in: file, reverse: false)
            try await self.client.applyPatch(patch, cached: true, reverse: false, in: self.repo.path)
        }
        if let target = diffTarget {
            await showDiff(target)
        }
    }

    /// Unstages one hunk (from the staged diff shown by `showDiff`) back out
    /// of the index. `PatchBuilder` builds the INVERSE hunk (`reverse:
    /// true`) — this is the direction that reaches the add/delete path a
    /// prior review flagged as untested (fixed and covered by the
    /// fix-forward tests in `GitClientIntegrationTests`). That inverse patch
    /// is already correctly oriented to turn the current index content back
    /// into HEAD's, so `applyPatch` applies it PLAIN (`cached: true,
    /// reverse: false`) — NOT `reverse: true`: pairing a reverse-BUILT patch
    /// with `git apply --reverse` is a double reversal that `git apply`
    /// rejects (verified against real git; see the fix-forward tests' doc
    /// comment). Same `performAction` + diff-reload shape as `stageHunk`.
    public func unstageHunk(_ hunk: Hunk, in file: FileDiff) async {
        await performAction(allowInProgress: true) {
            try await self.validateDisplayedHunk(hunk, file: file, staged: true)
            let patch = try PatchBuilder.checkedPatch(for: hunk, in: file, reverse: true)
            try await self.client.applyPatch(patch, cached: true, reverse: false, in: self.repo.path)
        }
        if let target = diffTarget {
            await showDiff(target)
        }
    }

    private func validateDisplayedHunk(_ hunk: Hunk, file: FileDiff, staged: Bool) async throws {
        let current = try await client.diff(path: file.displayPath, staged: staged, in: repo.path)
        guard file.hunks.contains(hunk), current == file else {
            throw GitError(command: "git apply", exitCode: -1,
                           stderr: "This diff changed on disk. Review the refreshed diff before applying a hunk.")
        }
    }

    public var operationIdentity: RepositoryOperationIdentity {
        RepositoryOperationIdentity(context: context, branch: status?.branch, oid: status?.oid,
                                    operationFiles: context.map { RepositoryOperationState.fingerprint(in: $0) })
    }

    /// Refreshes `prInfo` from `gh pr list` for the current branch. Passive
    /// like `refreshStashes`/`refreshStatus`: no `isBusy`, no
    /// `actionError` — a failed or slow `gh` call just clears `prInfo`
    /// (nothing shows), it never blocks git actions or paints a banner for
    /// what is an entirely optional integration. Own in-flight guard
    /// (`isRefreshingPR`) so a slow call can't be piled onto by a second.
    ///
    /// Skipped when the last fetch is still within `prInfoTTL` FOR THE SAME
    /// branch, unless `force` (used by `push()`, where a push can change CI
    /// state right away). A branch change bypasses the TTL and drops the
    /// now-wrong cached `prInfo` up front, so a different branch's PR badge
    /// is never left showing. No branch (`status?.branch` nil — e.g.
    /// detached HEAD, or `status` itself not yet loaded) clears everything
    /// and returns without touching `gh`.
    public func refreshPRInfo(using gh: GhClient, force: Bool = false) async {
        guard let branch = status?.branch, branch != "(detached)" else {
            prRefreshTask?.cancel()
            prRefreshTask = nil
            prRequestedBranch = nil
            prRefreshGeneration += 1
            prInfo = nil
            prInfoBranch = nil
            prInfoFetchedAt = nil
            return
        }
        if !force, branch == prInfoBranch, let date = prInfoFetchedAt,
           clock().timeIntervalSince(date) < Self.prInfoTTL { return }
        if !force, prRequestedBranch == branch, let task = prRefreshTask, !task.isCancelled { await task.value; return }
        prRefreshTask?.cancel()
        prRefreshGeneration += 1
        let generation = prRefreshGeneration
        prRequestedBranch = branch
        if branch != prInfoBranch { prInfo = nil }
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == self.prRefreshGeneration {
                    self.prRequestedBranch = nil
                    self.prRefreshTask = nil
                }
            }
            do {
                let result: PullRequestInfo?
                if let loader = self.reviewLoader { result = try await loader(branch, self.repo.path, self.client.gitPath) }
                else { result = try await gh.pullRequest(forBranch: branch, in: self.repo.path, gitPath: self.client.gitPath) }
                guard !Task.isCancelled, generation == self.prRefreshGeneration,
                      self.status?.branch == branch else { return }
                self.prInfo = result
                self.prInfoBranch = branch
                self.prInfoFetchedAt = self.clock()
                self.hostingError = nil
            } catch {
                guard !Task.isCancelled, generation == self.prRefreshGeneration else { return }
                self.hostingError = error.localizedDescription
            }
        }
        prRefreshTask = task
        await task.value
    }

    /// Debounces `historyQuery` edits: cancels any prior pending search in
    /// the shared `historySearchTask` slot, waits 300ms, then runs
    /// `refreshLog()` — unless a newer keystroke or field change cancelled
    /// this task first (checked before the sleep and again after it).
    /// That cancellation is only a best-effort short-circuit: it stops this
    /// `Task` from ever calling `refreshLog()`, but it cannot stop a git
    /// subprocess that is already running. The actual guarantee against a
    /// stale result clobbering a newer one is `refreshLog()`'s generation
    /// counter (`historyGeneration`), which both this method and
    /// `historyFieldChanged()` funnel through — see `refreshLog()` for how
    /// that guard works.
    public func scheduleHistorySearch() {
        historySearchTask?.cancel()
        historySearchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.refreshLog()
        }
    }

    /// Immediately reschedules `refreshLog()` for a `historyField` (scope)
    /// change: cancels any pending/in-flight search in the same
    /// `historySearchTask` slot used by `scheduleHistorySearch()` — so a
    /// slow content-scope search and a fast field-change search are never
    /// both left running untracked — then runs the refresh with no debounce
    /// delay. `refreshLog()`'s generation counter is the final backstop if
    /// the cancelled task's git subprocess still completes.
    public func historyFieldChanged() {
        historySearchTask?.cancel()
        historySearchTask = Task { [weak self] in
            await self?.refreshLog()
        }
    }

    /// Commits currently staged changes with `commitMessage`. No-op unless
    /// the trimmed message is non-empty, something is staged, and no other
    /// action is already running. On success, clears the draft message and
    /// refreshes both status and log so staged changes and the new commit
    /// show up immediately.
    @discardableResult
    public func commit() async -> OperationResult {
        let submittedDraft = commitMessage
        let trimmed = submittedDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, hasStagedChanges else { return .skipped("Nothing staged or no commit message") }
        return await performAction(refreshingLog: true) {
            try await self.client.commit(message: trimmed, in: self.repo.path)
            if self.commitMessage == submittedDraft { self.commitMessage = "" }
            if let record = self.undoRecord {
                await self.client.discardUndoSnapshot(record.snapshot, in: self.repo.path)
                self.undoRecord = nil
            }
        }
    }

    /// Pulls from upstream, then refreshes status and log — new commits may
    /// have arrived. Rewrites local history (a merge or fast-forward moves
    /// HEAD), so it always snapshots first via `writeUndoSnapshot`; if the
    /// pull turned out to be a no-op (HEAD didn't move), the snapshot is
    /// noise and is discarded immediately rather than left around as a
    /// dead undo target.
    @discardableResult
    public func pull() async -> OperationResult {
        await performAction(refreshingLog: true) {
            let snapshot = try await self.client.writeUndoSnapshot(in: self.repo.path)
            // `writeUndoSnapshot` prunes any prior undo ref, so a record from
            // an earlier sync now points at a deleted ref. Clear it up front,
            // before the pull — which may throw and skip the promote/discard
            // below, leaving the stale record behind otherwise.
            self.undoRecord = nil
            try await self.client.pull(in: self.repo.path)
            let postOpHead = try await self.client.headOID(in: self.repo.path)
            if postOpHead == snapshot.oid {
                await self.client.discardUndoSnapshot(snapshot, in: self.repo.path)
            } else {
                self.undoRecord = UndoRecord(snapshot: snapshot, postOpHead: postOpHead, description: "pull")
            }
        }
    }

    /// Pushes local commits upstream, refreshing status for the new
    /// ahead/behind counts. With `autoRebaseOnRejectedPush` set, a
    /// non-fast-forward rejection triggers `git pull --rebase --autostash`
    /// and a single retry — and since that can pull new commits in, the log
    /// is refreshed too in that mode; stashes are refreshed too, since an
    /// autostash-pop conflict during the rebase leaves a real stash entry
    /// behind.
    ///
    /// That rebase-and-retry is the only branch of `push()` that rewrites
    /// local history, so it's the only branch that snapshots — and only
    /// when the toggle is actually on, so a plain push never pays for a
    /// snapshot it can't use. A clean `.pushed` outcome means no rebase
    /// happened, so the snapshot is noise and is discarded immediately.
    ///
    /// `gh`, when non-nil, is used at the tail — after either branch — to
    /// force a fresh `refreshPRInfo`: a push can change the branch's CI
    /// state (new commits landed) or turn a fresh push into a PR's first
    /// CI run, so the 5-minute TTL is bypassed here. Callers pass nil when
    /// `AppModel.isGhAvailable` is false, which skips the refresh entirely.
    public func push(using gh: GhClient? = nil) async {
        if autoRebaseOnRejectedPush {
            // `refreshingStashes: true` because an autostash-pop conflict
            // during `pull --rebase --autostash` leaves a real stash entry
            // behind — without this it stays hidden until the repo is
            // reselected.
            await performAction(refreshingLog: true, refreshingStashes: true) {
                let snapshot = try await self.client.writeUndoSnapshot(in: self.repo.path)
                // See `pull()`: the snapshot write prunes any prior undo ref,
                // so clear the now-stale record before the push, which may
                // throw before the promote/discard below runs.
                self.undoRecord = nil
                let outcome = try await self.client.pushWithAutoRebase(in: self.repo.path)
                if outcome == .rebasedAndPushed {
                    self.actionNotice = "Push rejected — rebased onto \(self.status?.upstream ?? "remote") and pushed"
                    let postOpHead = try await self.client.headOID(in: self.repo.path)
                    self.undoRecord = UndoRecord(snapshot: snapshot, postOpHead: postOpHead, description: "auto-rebase push")
                } else {
                    await self.client.discardUndoSnapshot(snapshot, in: self.repo.path)
                }
            }
        } else {
            await performAction { try await self.client.push(in: self.repo.path) }
        }
        if actionError == nil, let gh {
            await refreshPRInfo(using: gh, force: true)
        }
    }

    /// Restores HEAD to the last recorded `undoRecord`'s snapshot. No-op if
    /// there is none. On success, clears `undoRecord` and surfaces a
    /// confirmation via `actionNotice`; on failure (the moved-on guard, or
    /// `reset --keep` refusing because the restore would clobber dirty
    /// work), `undoRecord` is left intact and the failure surfaces through
    /// the normal `actionError` path instead.
    public func undoLastSync() async {
        guard let record = undoRecord else { return }
        await performAction(refreshingLog: true) {
            do {
                try await self.client.restoreUndoSnapshot(
                    record.snapshot, expectedHead: record.postOpHead, in: self.repo.path
                )
            } catch let error as GitError where error.isMovedOnSinceSnapshot {
                // The repo moved on since the snapshot (external commit or
                // HEAD move) — the record is now known-stale, so clear it
                // before rethrowing to `performAction`'s error banner.
                // Other failures (e.g. `reset --keep` refusing a
                // dirty-clobber) leave the record intact so the user can
                // retry after cleaning up.
                self.undoRecord = nil
                throw error
            }
            self.undoRecord = nil
            self.actionNotice = "Restored to \(String(record.snapshot.oid.prefix(7))). Remote unchanged."
        }
    }

    /// Fetches from upstream without merging — updates ahead/behind counts.
    @discardableResult
    public func fetch() async -> OperationResult {
        await performAction { try await self.client.fetch(in: self.repo.path) }
    }

    /// Stashes the current changes. `message` is optional (`git stash push`
    /// falls back to its own default subject); `includeUntracked` maps to
    /// `--include-untracked`. `performAction` already refreshes `status`
    /// afterward; `refreshingStashes` additionally refreshes `stashes` so the
    /// new entry shows up immediately.
    public func stashPush(message: String?, includeUntracked: Bool) async {
        await performAction(refreshingStashes: true) {
            try await self.client.stashPush(message: message, includeUntracked: includeUntracked, in: self.repo.path)
        }
    }

    /// Applies `stash@{index}` without dropping it.
    public func stashApply(_ entry: StashEntry) async {
        await performAction(refreshingStashes: true) { try await self.client.stashApply(entry, in: self.repo.path) }
    }

    /// Applies `stash@{index}` and drops it on success.
    public func stashPop(_ entry: StashEntry) async {
        await performAction(refreshingStashes: true) { try await self.client.stashPop(entry, in: self.repo.path) }
    }

    /// Drops `stash@{index}` without applying it. Confirmation lives in the
    /// view (`StashSection`'s `.confirmationDialog`) — this method just does
    /// the drop.
    public func stashDrop(_ entry: StashEntry) async {
        await performAction(refreshingStashes: true) { try await self.client.stashDrop(entry, in: self.repo.path) }
    }

    public func toggleCommandPane() {
        isCommandPaneVisible.toggle()
    }

    /// Runs `commandInput` (trimmed) via the user's login shell in the
    /// repo's directory, streaming its output into `commandOutput`. No-op if
    /// blank or a command is already running.
    ///
    /// Commands can mutate Git or working files. They hold the shared
    /// repository coordinator and block other actions until process cleanup
    /// finishes, including after Stop. `isRunningCommand` and command output
    /// report their progress separately from `performAction`'s error banner.
    public func runCommand() {
        let cmd = commandInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty, !isRunningCommand, !isBusy else { return }

        commandHistory.append(cmd)
        commandInput = ""
        appendOutput("$ \(cmd)\n")

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        isRunningCommand = true
        commandTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isRunningCommand = false
                self.commandTask = nil
                Task { await self.refreshForExternalChange() }
            }
            var acquiredKey: String?
            var streamingProcess: StreamingProcess?
            do {
                let context = try await RepositoryContext.resolve(in: self.repo.path, gitPath: self.client.gitPath)
                try await RepositoryMutationCoordinator.shared.acquire(context.commonGitDir.path)
                acquiredKey = context.commonGitDir.path
                try Task.checkCancellation()
                let process = ProcessRunner.startStreaming(
                    shell, arguments: ["-lc", cmd], workingDirectory: self.repo.path, priority: .interactive
                )
                streamingProcess = process
                for try await event in process.events {
                    switch event {
                    case .output(_, let text):
                        self.appendOutput(AnsiStripper.strip(text))
                    case .exit(let code):
                        if code != 0 {
                            self.appendOutput("[exited \(code)]\n")
                        }
                    }
                }
            } catch {
                self.appendOutput("[failed to run: \(error)]\n")
            }
            if let streamingProcess {
                if Task.isCancelled { streamingProcess.cancel() }
                // Stream cancellation finishes its iterator before the process
                // group exits. Keep the repository locked and busy until reaped.
                await streamingProcess.waitForCompletion()
            }
            if let acquiredKey { await RepositoryMutationCoordinator.shared.release(acquiredKey) }
        }
    }

    /// Cancels the in-flight command, if any.
    public func cancelCommand() {
        guard isRunningCommand else { return }
        appendOutput("[stopped]\n")
        commandTask?.cancel()
    }

    /// Appends `text` to `commandOutput`, then — if that pushed it past
    /// `Self.commandOutputCap` characters — drops from the front up to the
    /// next line boundary, so the cap never splits a line mid-way.
    private func appendOutput(_ text: String) {
        commandOutput += text
        // O(1) guard: Swift's native String stores its UTF-8 byte count, so
        // `utf8.count` doesn't rescan the way `.count` (grapheme segmentation)
        // would — cheap to check on every chunk. The O(n) trim below only
        // runs once output crosses the high-water mark, not per chunk.
        guard commandOutput.utf8.count > Self.commandOutputHighWater else { return }
        let overflow = commandOutput.count - Self.commandOutputCap
        guard overflow > 0 else { return }
        let dropPoint = commandOutput.index(commandOutput.startIndex, offsetBy: overflow)
        if let newline = commandOutput[dropPoint...].firstIndex(of: "\n") {
            commandOutput.removeSubrange(commandOutput.startIndex...newline)
        } else {
            commandOutput.removeSubrange(commandOutput.startIndex..<dropPoint)
        }
    }

    /// Background fetch uses the shared repository coordinator and sets
    /// `isBusy` while it runs, so linked worktrees and user actions cannot
    /// mutate shared Git metadata concurrently. It uses the background
    /// subprocess lane and reports failures in `lastAutoFetchError` instead
    /// of the foreground action banner.
    public func autoFetch() async {
        guard !isBusy, !isRunningCommand, !isMissing else { return }
        isBusy = true
        defer { isBusy = false }
        var acquiredKey: String?
        do {
            let context = try await RepositoryContext.resolve(in: repo.path, gitPath: client.gitPath)
            try await RepositoryMutationCoordinator.shared.acquire(context.commonGitDir.path)
            acquiredKey = context.commonGitDir.path
            try Task.checkCancellation()
            try await client.fetch(in: repo.path, priority: .background)
            lastAutoFetchError = nil
        } catch {
            lastAutoFetchError = error.localizedDescription
        }
        if let acquiredKey { await RepositoryMutationCoordinator.shared.release(acquiredKey) }
        await refreshStatus()
    }

    /// Shared shape for every mutating action: skip if already busy, mark
    /// busy for the duration, record failure in `actionError` (clearing it on
    /// success), then refresh status regardless of outcome. Sync actions
    /// (`pull`) additionally refresh the log, since new commits may have
    /// arrived; stash actions refresh the stash list. Both refreshes run
    /// while still `isBusy`, so a follow-up action can't fire against a
    /// stale log/stash list — `stash@{N}` indices in particular shift on
    /// drop/pop, so the list must be back in sync before the guard reopens.
    @discardableResult
    public func performAction(
        refreshingLog: Bool = false,
        refreshingStashes: Bool = false,
        allowInProgress: Bool = false,
        expectedIdentity: RepositoryOperationIdentity? = nil,
        _ operation: () async throws -> Void
    ) async -> OperationResult {
        guard !isBusy, !isRunningCommand else { return .skipped("Repository is busy") }
        isBusy = true
        defer { isBusy = false }
        actionNotice = nil
        let expected = expectedIdentity ?? operationIdentity
        let result: OperationResult
        var acquiredKey: String?
        do {
            let resolved = try await RepositoryContext.resolve(in: repo.path, gitPath: client.gitPath)
            context = resolved
            try await RepositoryMutationCoordinator.shared.acquire(resolved.commonGitDir.path)
            acquiredKey = resolved.commonGitDir.path
            try Task.checkCancellation()
            let currentContext = try await RepositoryContext.resolve(in: repo.path, gitPath: client.gitPath)
            let currentStatus = try await client.status(in: repo.path)
            guard currentContext == resolved,
                  expected.context == nil || expected.context == currentContext,
                  expected.branch == nil || expected.branch == currentStatus.branch,
                  expected.oid == nil || expected.oid == currentStatus.oid,
                  expected.operationFiles == nil || expected.operationFiles == RepositoryOperationState.fingerprint(in: currentContext) else {
                throw GitError(command: "git", exitCode: -1,
                               stderr: "The repository or current branch changed. Review the refreshed state before trying again.")
            }
            operationState = RepositoryOperationState.read(in: resolved)
            guard allowInProgress || operationState == .normal else {
                throw GitError(command: "git", exitCode: -1,
                               stderr: "\(operationState.label). Resolve, continue, or abort that operation first.")
            }
            try await operation()
            actionError = nil
            result = .succeeded
        } catch is CancellationError {
            result = .skipped("Cancelled")
        } catch let error as GitError {
            actionError = error
            result = .failed(error.localizedDescription)
        } catch {
            actionError = GitError(command: "git", exitCode: -1, stderr: error.localizedDescription)
            result = .failed(error.localizedDescription)
        }
        if let acquiredKey { await RepositoryMutationCoordinator.shared.release(acquiredKey) }
        await refreshStatus()
        await refreshContext()
        if refreshingLog { await refreshLog() }
        if refreshingStashes { await refreshStashes() }
        refreshRevision += 1
        return result
    }
}

public struct RepositoryOperationIdentity: Sendable, Equatable {
    public let context: RepositoryContext?
    public let branch: String?
    public let oid: String?
    public let operationFiles: [String: Data]?
}

public enum RepositorySection: String, CaseIterable, Sendable {
    case changes = "Changes"
    case history = "History"
    case branches = "Branches & Worktrees"
    case conflicts = "Conflicts"
    case reviews = "Reviews"
}
