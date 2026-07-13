import Foundation
import Observation
import RepoDeckKit

/// View model for a single tracked repo: owns its live status and the
/// coalesced refresh that keeps it current.
@MainActor
@Observable
final class RepoViewModel: @MainActor Identifiable {
    let repo: Repo
    let client: GitClient

    var status: RepoStatus?
    var statusError: String?
    var isMissing = false
    /// Draft commit message bound to `CommitBoxView`'s text field.
    var commitMessage: String = ""
    /// Populated by `refreshLog()`; rendered by `HistoryListView`.
    var commits: [Commit] = []
    /// Free-text history search bound to `HistoryListView`'s search field.
    /// Trimmed empty (the default) means "no filter" — `refreshLog()` falls
    /// back to the full `client.log(in:)`.
    var historyQuery: String = ""
    /// Which axis `historyQuery` is matched against.
    var historyField: HistorySearchField = .message
    /// True while a stage/unstage/commit/sync action is running; `refreshStatus`
    /// never touches this — refresh is a passive, always-allowed operation.
    var isBusy = false
    /// Set by a failed stage/unstage/commit/sync action; cleared on the next
    /// successful action. Rendered by `ErrorBanner` in `RepoDetailView`.
    var actionError: GitError?
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

    /// Coalescing pair: only one `git status` runs per repo at a time. A call
    /// that arrives mid-refresh is folded into a single trailing refresh
    /// instead of piling up concurrent invocations.
    private var refreshInFlight = false
    private var refreshQueued = false

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

    var id: String { repo.id }

    /// True when `status` has at least one change staged for commit.
    var hasStagedChanges: Bool { status?.changes.contains { $0.area == .staged } ?? false }

    init(repo: Repo, client: GitClient) {
        self.repo = repo
        self.client = client
    }

    /// Refreshes `status` from disk. Safe to call from multiple call sites
    /// (rescan, watcher, manual refresh) without racing: if a refresh is
    /// already running, this marks one more trailing refresh and returns.
    func refreshStatus() async {
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
    func stage(_ change: FileChange) async {
        await performAction { try await client.stage([change.path], in: repo.path) }
    }

    /// Unstages a single change.
    func unstage(_ change: FileChange) async {
        await performAction { try await client.unstage([change.path], in: repo.path) }
    }

    /// Stages everything, tracked and untracked (`git add -A`).
    func stageAll() async {
        await performAction { try await client.stageAll(in: repo.path) }
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
    func refreshLog() async {
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
    func scheduleHistorySearch() {
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
    func historyFieldChanged() {
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
    func commit() async {
        let trimmedMessage = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty, hasStagedChanges, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        actionNotice = nil
        do {
            try await client.commit(message: trimmedMessage, in: repo.path)
            actionError = nil
            commitMessage = ""
            await refreshStatus()
            await refreshLog()
        } catch let error as GitError {
            actionError = error
        } catch {
            actionError = GitError(command: "git", exitCode: -1, stderr: error.localizedDescription)
        }
    }

    /// Pulls from upstream, then refreshes status and log — new commits may
    /// have arrived.
    func pull() async {
        await performAction(refreshingLog: true) { try await self.client.pull(in: self.repo.path) }
    }

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

    /// Fetches from upstream without merging — updates ahead/behind counts.
    func fetch() async {
        await performAction { try await self.client.fetch(in: self.repo.path) }
    }

    /// Shared shape for every mutating action: skip if already busy, mark
    /// busy for the duration, record failure in `actionError` (clearing it on
    /// success), then refresh status regardless of outcome. Sync actions
    /// (`pull`) additionally refresh the log, since new commits may have
    /// arrived.
    private func performAction(refreshingLog: Bool = false, _ operation: () async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        actionNotice = nil
        do {
            try await operation()
            actionError = nil
        } catch let error as GitError {
            actionError = error
        } catch {
            actionError = GitError(command: "git", exitCode: -1, stderr: error.localizedDescription)
        }
        await refreshStatus()
        if refreshingLog {
            await refreshLog()
        }
    }
}
