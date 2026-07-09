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

    /// Coalescing pair: only one `git status` runs per repo at a time. A call
    /// that arrives mid-refresh is folded into a single trailing refresh
    /// instead of piling up concurrent invocations.
    private var refreshInFlight = false
    private var refreshQueued = false

    /// The in-flight debounced search reschedule, if any. Cancelled and
    /// replaced by every call to `scheduleHistorySearch()`, so only the
    /// most recent keystroke's search actually runs.
    private var historySearchTask: Task<Void, Never>?

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
    /// beats a blank one. If the enclosing `Task` was cancelled (e.g. a
    /// debounced search superseded by a newer keystroke, or a killed git
    /// subprocess surfacing as a `GitError`), the failure is dropped instead
    /// of clobbering `actionError` with a stale/spurious error.
    func refreshLog() async {
        do {
            let trimmedQuery = historyQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedQuery.isEmpty {
                commits = try await client.log(in: repo.path)
            } else {
                let query = HistorySearchQuery(text: trimmedQuery, field: historyField)
                commits = try await client.searchLog(query, in: repo.path)
            }
        } catch let error as GitError {
            guard !Task.isCancelled else { return }
            actionError = error
        } catch {
            guard !Task.isCancelled else { return }
            actionError = GitError(command: "git", exitCode: -1, stderr: error.localizedDescription)
        }
    }

    /// Debounces `historyQuery` edits: cancels any prior pending search,
    /// waits 300ms, then runs `refreshLog()` — unless a newer keystroke
    /// cancelled this task first. A cancelled search must never clobber
    /// `actionError` or `commits` with a stale result, so cancellation is
    /// checked both before and after the sleep.
    func scheduleHistorySearch() {
        historySearchTask?.cancel()
        historySearchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
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

    /// Pushes local commits upstream. The log is unchanged by a push, but
    /// refreshing status anyway picks up the new ahead/behind counts.
    func push() async {
        await performAction { try await self.client.push(in: self.repo.path) }
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
