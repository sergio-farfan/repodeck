import AppKit
import Foundation
import Observation
import RepoDeckKit

/// App-wide state: tracked root folders, discovered repos, and scan status.
///
/// `trackedFolders` persists across launches via `UserDefaults.standard`
/// (`@AppStorage` does not work inside `@Observable` classes).
@MainActor
@Observable
final class AppModel {
    private static let trackedFolderPathsKey = "trackedFolderPaths"
    private static let pinnedRepoIDsKey = "pinnedRepoIDs"
    /// Minimum interval between watcher-triggered rescans. Guards against
    /// rescan storms when a burst of `.possibleNewRepo` events lands right
    /// after a rescan already ran (e.g. a multi-step `git clone`).
    private static let rescanStormInterval: TimeInterval = 2

    /// Progress for an in-flight bulk sync (`fetchAll`/`pullAll`).
    /// `verb` is a present-participle label for the toolbar, e.g. "Fetching".
    struct BulkProgress: Equatable {
        var verb: String
        var done: Int
        var total: Int
    }

    var trackedFolders: [URL]
    var repos: [RepoViewModel] = []
    var isScanning = false
    var selectedRepoID: String?
    var pinnedRepoIDs: Set<String>
    var filterText: String = ""
    /// Non-nil while `fetchAll`/`pullAll` is running. Also the reentrancy
    /// guard: a bulk op only starts when this is nil, so Fetch All and Pull
    /// All can never overlap, with each other or with themselves.
    var bulkProgress: BulkProgress?
    /// Transient failure count from the most recently finished bulk op.
    /// Per-repo errors live in each repo's own `actionError` (surfaced by
    /// that repo's `ErrorBanner` once selected); this is just a toolbar-level
    /// summary the user can dismiss.
    var bulkSummary: String?

    let client = GitClient()

    private let watcher = RepoWatcher()
    private var watcherTask: Task<Void, Never>?
    private var lastRescanAt: Date?

    init() {
        let paths = UserDefaults.standard.stringArray(forKey: Self.trackedFolderPathsKey) ?? []
        trackedFolders = paths.map { URL(fileURLWithPath: $0) }

        let pinnedIDs = UserDefaults.standard.stringArray(forKey: Self.pinnedRepoIDsKey) ?? []
        pinnedRepoIDs = Set(pinnedIDs)

        watcherTask = Task { [weak self] in
            guard let events = self?.watcher.events else { return }
            for await event in events {
                await self?.handle(event)
            }
        }
    }

    isolated deinit {
        watcherTask?.cancel()
        watcher.stop()
    }

    /// Repos matching `filterText` (name or branch, case-insensitive) that are
    /// pinned, alphabetical. Empty when no pinned repo matches.
    var filteredPinned: [RepoViewModel] {
        filteredAndSorted(repos.filter { pinnedRepoIDs.contains($0.id) })
    }

    /// Repos matching `filterText` that are not pinned, alphabetical.
    var filteredUnpinned: [RepoViewModel] {
        filteredAndSorted(repos.filter { !pinnedRepoIDs.contains($0.id) })
    }

    /// Adds or removes `id` from the pinned set and persists it.
    func togglePin(_ id: String) {
        if pinnedRepoIDs.contains(id) {
            pinnedRepoIDs.remove(id)
        } else {
            pinnedRepoIDs.insert(id)
        }
        UserDefaults.standard.set(Array(pinnedRepoIDs), forKey: Self.pinnedRepoIDsKey)
    }

    /// Drops a repo from the in-memory list only (e.g. a missing repo the
    /// user dismissed). It returns on the next rescan if still on disk.
    func removeRepo(_ id: String) {
        repos.removeAll { $0.id == id }
        if selectedRepoID == id {
            selectedRepoID = nil
        }
    }

    /// Concurrently refreshes every repo's status. `ProcessRunner`'s global
    /// semaphore bounds real subprocess concurrency, so no extra limiter here.
    func refreshAllStatuses() async {
        await withTaskGroup(of: Void.self) { group in
            for vm in repos {
                group.addTask { await vm.refreshStatus() }
            }
        }
    }

    /// Concurrently fetches every non-missing repo. See `runBulk` for the
    /// concurrency, guard, and error-reporting discipline shared with `pullAll`.
    func fetchAll() async {
        await runBulk(progressVerb: "Fetching", summaryLabel: "Fetch All") { await $0.fetch() }
    }

    /// Concurrently pulls every non-missing repo. See `runBulk`.
    func pullAll() async {
        await runBulk(progressVerb: "Pulling", summaryLabel: "Pull All") { await $0.pull() }
    }

    /// Shared bulk-op driver for `fetchAll`/`pullAll`.
    ///
    /// Guarded by `bulkProgress`: a second call while one is already running
    /// (from either method) is a no-op, so bulk ops never overlap. Fans one
    /// `action` per repo out via `withTaskGroup`; `ProcessRunner`'s global
    /// semaphore — not this loop — bounds real subprocess concurrency, same
    /// as `refreshAllStatuses`. Each repo's own `performAction` discipline
    /// records that repo's failure in its own `actionError`; this driver only
    /// tallies how many repos failed, for the toolbar-level `bulkSummary`.
    private func runBulk(
        progressVerb: String,
        summaryLabel: String,
        action: @escaping @Sendable (RepoViewModel) async -> Void
    ) async {
        guard bulkProgress == nil else { return }
        let targets = repos.filter { !$0.isMissing }
        guard !targets.isEmpty else { return }

        bulkSummary = nil
        bulkProgress = BulkProgress(verb: progressVerb, done: 0, total: targets.count)

        await withTaskGroup(of: Void.self) { group in
            for vm in targets {
                group.addTask {
                    await action(vm)
                    await self.incrementBulkDone()
                }
            }
        }

        let failureCount = targets.filter { $0.actionError != nil }.count
        if failureCount > 0 {
            bulkSummary = "\(summaryLabel): \(failureCount) of \(targets.count) failed — select a repo to see its error"
        }
        bulkProgress = nil
    }

    /// Increments `bulkProgress.done` on the main actor as each repo's bulk
    /// action completes. A dedicated method (rather than mutating the
    /// property directly from inside a task-group child task) keeps the hop
    /// onto the main actor explicit, mirroring how every cross-actor call in
    /// this file goes through an isolated method.
    private func incrementBulkDone() {
        bulkProgress?.done += 1
    }

    /// Presents an `NSOpenPanel` for choosing one or more folders, appends any
    /// not already tracked, persists, and kicks off a rescan.
    func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"

        guard panel.runModal() == .OK else { return }

        let existingPaths = Set(trackedFolders.map { $0.standardizedFileURL.path })
        let newFolders = panel.urls.filter { !existingPaths.contains($0.standardizedFileURL.path) }
        guard !newFolders.isEmpty else { return }

        trackedFolders.append(contentsOf: newFolders)
        saveTrackedFolders()
        Task { await rescan() }
    }

    /// Removes a tracked folder, persists, and kicks off a rescan.
    func removeFolder(_ url: URL) {
        let targetPath = url.standardizedFileURL.path
        trackedFolders.removeAll { $0.standardizedFileURL.path == targetPath }
        saveTrackedFolders()
        Task { await rescan() }
    }

    /// Re-scans every tracked folder for git repos and rebuilds `repos`.
    ///
    /// Re-entrant calls are ignored while a scan is already running.
    func rescan() async {
        guard !isScanning else { return }
        isScanning = true
        lastRescanAt = Date()
        defer { isScanning = false }

        let roots = trackedFolders
        let discovered = await Task.detached(priority: .userInitiated) { () -> [Repo] in
            let scanner = RepoScanner()
            var found: [Repo] = []
            for root in roots {
                found.append(contentsOf: scanner.scan(root: root))
            }
            return found
        }.value

        // De-duplicate by id (overlapping roots can rediscover the same repo);
        // the first occurrence — from the earliest root — wins.
        var seenIDs = Set<String>()
        var deduped: [Repo] = []
        for repo in discovered where seenIDs.insert(repo.id).inserted {
            deduped.append(repo)
        }
        deduped.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        // Reuse existing view models by id so future per-repo state survives a rescan.
        let existingByID = Dictionary(uniqueKeysWithValues: repos.map { ($0.id, $0) })
        repos = deduped.map { repo in
            existingByID[repo.id] ?? RepoViewModel(repo: repo, client: client)
        }

        if let selectedRepoID, !repos.contains(where: { $0.id == selectedRepoID }) {
            self.selectedRepoID = nil
        }

        // Re-arm the watcher with the freshly discovered repo set so live
        // refresh and auto-discovery keep working after every rescan.
        watcher.setWatched(roots: trackedFolders, repoPaths: repos.map(\.repo.path))

        await refreshAllStatuses()
    }

    /// Handles a debounced watcher event. Runs on the main actor: the
    /// consumer `Task` in `init` inherits this actor's isolation, so no
    /// explicit hop is needed here.
    private func handle(_ event: WatchEvent) async {
        switch event {
        case .repoChanged(let url):
            let target = url.standardizedFileURL.path
            guard let vm = repos.first(where: { $0.repo.path.standardizedFileURL.path == target }) else {
                return
            }
            await vm.refreshStatus()

        case .possibleNewRepo:
            guard !isScanning else { return }
            if let lastRescanAt, Date().timeIntervalSince(lastRescanAt) < Self.rescanStormInterval {
                return
            }
            await rescan()
        }
    }

    private func saveTrackedFolders() {
        let paths = trackedFolders.map { $0.path }
        UserDefaults.standard.set(paths, forKey: Self.trackedFolderPathsKey)
    }

    private func filteredAndSorted(_ list: [RepoViewModel]) -> [RepoViewModel] {
        list
            .filter { matchesFilter($0) }
            .sorted { $0.repo.name.localizedCaseInsensitiveCompare($1.repo.name) == .orderedAscending }
    }

    private func matchesFilter(_ vm: RepoViewModel) -> Bool {
        guard !filterText.isEmpty else { return true }
        if vm.repo.name.localizedCaseInsensitiveContains(filterText) { return true }
        if let branch = vm.status?.branch, branch.localizedCaseInsensitiveContains(filterText) { return true }
        return false
    }
}
