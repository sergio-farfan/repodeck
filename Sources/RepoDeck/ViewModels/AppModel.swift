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

    var trackedFolders: [URL]
    var repos: [RepoViewModel] = []
    var isScanning = false
    var selectedRepoID: String?
    var pinnedRepoIDs: Set<String>
    var filterText: String = ""

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
