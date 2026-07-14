import AppKit
import Foundation
import Observation
import RepoDeckKit

/// App-wide state: tracked root folders, discovered repos, and scan status.
///
/// `trackedFolders` persists across launches via `UserDefaults.standard`
/// (`@AppStorage` does not work inside `@Observable` classes). Per-repo
/// settings (pin, auto-rebase, ...) persist the same way, as a single
/// `repoSettingsByID` dictionary under `repoSettings.v1` — see that
/// property's doc comment.
@MainActor
@Observable
final class AppModel {
    private static let trackedFolderPathsKey = "trackedFolderPaths"
    /// Legacy pinned-repo-IDs key. Read-only from this commit on: it feeds
    /// `RepoSettingsMigration` on first launch after the `repoSettings.v1`
    /// switchover (and again if that data is ever found corrupt), but is
    /// never written again.
    private static let pinnedRepoIDsKey = "pinnedRepoIDs"
    /// Legacy auto-rebase-repo-IDs key. Read-only — see `pinnedRepoIDsKey`.
    private static let autoRebaseRepoIDsKey = "autoRebaseRepoIDs"
    /// Consolidated per-repo settings store. Supersedes `pinnedRepoIDsKey`/
    /// `autoRebaseRepoIDsKey`; see `repoSettingsByID`.
    private static let repoSettingsKey = "repoSettings.v1"
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
    /// The repo whose settings sheet is presented; nil = no sheet.
    var repoSettingsTarget: RepoViewModel?
    /// Consolidated per-repo settings (pin, auto-rebase, auto-fetch
    /// interval, group), keyed by repo id (i.e. path). Persisted as one
    /// JSON blob under `repoSettingsKey`. `private(set)`: `updateSettings`
    /// is the sole write path, so every write also re-persists and (for
    /// `autoRebaseOnRejectedPush`) re-mirrors onto the live `RepoViewModel`.
    private(set) var repoSettingsByID: [String: RepoSettings]
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
    /// Set when a `.possibleNewRepo` event arrives while a rescan is already
    /// running or inside the storm-guard window, instead of dropping the
    /// event on the floor. Consumed by the follow-up `Task` scheduled by
    /// `scheduleFollowUpRescan()`, which calls `rescan()` again so the event
    /// isn't lost.
    private var pendingRescan = false
    /// Guards `scheduleFollowUpRescan()` so at most one follow-up `Task` is
    /// ever in flight, whether it was scheduled from `rescan()`'s tail or
    /// from the storm-window branch of `handle(_:)`.
    private var isFollowUpScheduled = false

    init() {
        let paths = UserDefaults.standard.stringArray(forKey: Self.trackedFolderPathsKey) ?? []
        trackedFolders = paths.map { URL(fileURLWithPath: $0) }

        // Migration inputs are read unconditionally (cheap, and needed by
        // both the corrupt- and absent-key branches below); the legacy keys
        // themselves are never written again after this point.
        let legacyPinned = UserDefaults.standard.stringArray(forKey: Self.pinnedRepoIDsKey) ?? []
        let legacyAutoRebase = UserDefaults.standard.stringArray(forKey: Self.autoRebaseRepoIDsKey) ?? []

        if let data = UserDefaults.standard.data(forKey: Self.repoSettingsKey) {
            if let decoded = try? JSONDecoder().decode([String: RepoSettings].self, from: data) {
                repoSettingsByID = decoded
            } else {
                // Corrupt: recover by re-deriving from the legacy arrays.
                // Not re-saved here — the next `updateSettings` call (or a
                // future launch, harmlessly repeating this same recovery)
                // will persist a clean value.
                repoSettingsByID = RepoSettingsMigration.migrate(
                    legacyPinned: legacyPinned,
                    legacyAutoRebase: legacyAutoRebase
                )
            }
        } else {
            // Absent: first launch after this change. Migrate and save
            // immediately so the one-way valve engages now, not on the
            // user's first pin/toggle.
            repoSettingsByID = RepoSettingsMigration.migrate(
                legacyPinned: legacyPinned,
                legacyAutoRebase: legacyAutoRebase
            )
            saveRepoSettings()
        }

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
        filteredAndSorted(repos.filter { settings(for: $0.id).isPinned })
    }

    /// Unpinned repos partitioned by group, ordered by group name; excludes
    /// empty groups (a group exists only through its members).
    var groupedSections: [(name: String, repos: [RepoViewModel])] {
        let unpinned = repos.filter { !settings(for: $0.id).isPinned }
        let byGroup = Dictionary(grouping: unpinned.filter { settings(for: $0.id).group != nil },
                                 by: { settings(for: $0.id).group! })
        return byGroup.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .compactMap { name in
                let members = filteredAndSorted(byGroup[name] ?? [])
                return members.isEmpty ? nil : (name: name, repos: members)
            }
    }

    /// Unpinned repos with no group, filtered + sorted (the "Repositories" section).
    var filteredUngrouped: [RepoViewModel] {
        filteredAndSorted(repos.filter { !settings(for: $0.id).isPinned && settings(for: $0.id).group == nil })
    }

    /// The settings for `id`, or all-default values if `id` has no entry
    /// (i.e. it has never had a non-default setting).
    func settings(for id: String) -> RepoSettings {
        repoSettingsByID[id] ?? RepoSettings()
    }

    /// Sorted unique non-nil group names currently assigned to any repo.
    /// Backs the settings sheet's Group picker; a later groups feature task
    /// reuses it for the sidebar.
    var groupNames: [String] {
        Array(Set(repoSettingsByID.values.compactMap(\.group))).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    /// Sole write path for per-repo settings: mutates a copy, prunes it back
    /// out of the dictionary if it round-tripped to all-default, persists,
    /// and mirrors the auto-rebase flag onto the live view model (if any) so
    /// the next `push()` picks it up.
    func updateSettings(for id: String, _ mutate: (inout RepoSettings) -> Void) {
        var s = settings(for: id)
        mutate(&s)
        if s.isDefault { repoSettingsByID.removeValue(forKey: id) } else { repoSettingsByID[id] = s }
        saveRepoSettings()
        repos.first { $0.id == id }?.autoRebaseOnRejectedPush = s.autoRebaseOnRejectedPush
    }

    private func saveRepoSettings() {
        if let data = try? JSONEncoder().encode(repoSettingsByID) {
            UserDefaults.standard.set(data, forKey: Self.repoSettingsKey)
        }
    }

    /// Toggles `id`'s pinned flag and persists it.
    func togglePin(_ id: String) {
        updateSettings(for: id) { $0.isPinned.toggle() }
    }

    /// Toggles `id`'s auto-rebase flag, persists it, and updates the live
    /// view model's flag so the next Push picks it up.
    func toggleAutoRebase(_ id: String) {
        updateSettings(for: id) { $0.autoRebaseOnRejectedPush.toggle() }
    }

    /// Assigns `id` to group `name` (or ungroups it if `nil`) and persists it.
    func assignGroup(_ name: String?, to id: String) {
        updateSettings(for: id) { $0.group = name }
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
            if let existing = existingByID[repo.id] {
                return existing
            }
            let vm = RepoViewModel(repo: repo, client: client)
            vm.autoRebaseOnRejectedPush = settings(for: repo.id).autoRebaseOnRejectedPush
            return vm
        }

        if let selectedRepoID, !repos.contains(where: { $0.id == selectedRepoID }) {
            self.selectedRepoID = nil
        }

        // Re-arm the watcher with the freshly discovered repo set so live
        // refresh and auto-discovery keep working after every rescan.
        watcher.setWatched(roots: trackedFolders, repoPaths: repos.map(\.repo.path))

        await refreshAllStatuses()

        // A `.possibleNewRepo` event landed while this rescan owned the
        // guard (either `isScanning` or the storm window) and was recorded
        // rather than dropped. Schedule exactly one follow-up rescan so it
        // isn't lost.
        if pendingRescan {
            scheduleFollowUpRescan()
        }
    }

    /// Schedules the single follow-up rescan that consumes `pendingRescan`.
    ///
    /// Called both from `rescan()`'s tail and from the storm-window branch of
    /// `handle(_:)` — factored here so the "sleep, recheck, consume, rescan"
    /// logic exists exactly once. `isFollowUpScheduled` guards against
    /// stacking multiple concurrent follow-ups; it is cleared before
    /// `rescan()` runs so a `pendingRescan` set during that call schedules a
    /// fresh follow-up rather than being silently absorbed.
    private func scheduleFollowUpRescan() {
        guard !isFollowUpScheduled else { return }
        isFollowUpScheduled = true
        Task {
            try? await Task.sleep(for: .seconds(Self.rescanStormInterval))
            self.isFollowUpScheduled = false
            guard !self.isScanning, self.pendingRescan else { return }
            self.pendingRescan = false
            await self.rescan()
        }
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
            // Rather than dropping an event that arrives while a rescan
            // already owns the guard, remember it so a follow-up rescan can
            // pick it up once the guard clears — see `pendingRescan`. A
            // rescan already in flight will consume the flag itself via its
            // tail; the storm-window case below has no in-flight rescan to
            // do that, so it must schedule the follow-up itself or the flag
            // would never be consumed.
            guard !isScanning else {
                pendingRescan = true
                return
            }
            if let lastRescanAt, Date().timeIntervalSince(lastRescanAt) < Self.rescanStormInterval {
                pendingRescan = true
                scheduleFollowUpRescan()
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
