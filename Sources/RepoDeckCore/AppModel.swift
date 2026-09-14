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
public final class AppModel {
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
    /// Persists `isMenuBarExtraEnabled`.
    private static let menuBarEnabledKey = "menuBarExtra.enabled"
    /// Minimum interval between watcher-triggered rescans. Guards against
    /// rescan storms when a burst of `.possibleNewRepo` events lands right
    /// after a rescan already ran (e.g. a multi-step `git clone`).
    private static let rescanStormInterval: TimeInterval = 2

    /// Progress for an in-flight bulk sync (`fetchAll`/`pullAll`).
    /// `verb` is a present-participle label for the toolbar, e.g. "Fetching".
    public struct BulkProgress: Equatable {
        public var verb: String
        public var done: Int
        public var total: Int
    }

    public var trackedFolders: [URL]
    public var repos: [RepoViewModel] = []
    public var isScanning = false
    public var selectedRepoID: String?
    /// The repo whose settings sheet is presented; nil = no sheet.
    public var repoSettingsTarget: RepoViewModel?
    /// Captures the repository whose author settings are being edited.
    public var gitIdentityTarget: RepoViewModel?
    /// Whether the ⌘K command palette overlay is presented.
    public var isPaletteVisible = false
    /// Consolidated per-repo settings (pin, auto-rebase, auto-fetch
    /// interval, group, hidden), keyed by repo id (i.e. path). Persisted as one
    /// JSON blob under `repoSettingsKey`. `private(set)`: `updateSettings`
    /// is the sole write path, so every write also re-persists and (for
    /// `autoRebaseOnRejectedPush`) re-mirrors onto the live `RepoViewModel`.
    public private(set) var repoSettingsByID: [String: RepoSettings]
    public var filterText: String = ""
    public var attentionFilter: RepositoryAttentionFilter = .all
    public private(set) var workflowSettings: WorkflowSettings
    public var settingsError: String?
    /// Whether the `MenuBarExtra` presentation (see `RepoDeckApp`) is shown
    /// alongside the full window. Persisted; default off. The full window
    /// remains primary regardless of this flag — see the brief's YAGNI note.
    public var isMenuBarExtraEnabled: Bool {
        didSet {
            preferences.set(isMenuBarExtraEnabled, forKey: Self.menuBarEnabledKey)
        }
    }
    /// Non-nil while `fetchAll`/`pullAll` is running. Also the reentrancy
    /// guard: a bulk op only starts when this is nil, so Fetch All and Pull
    /// All can never overlap, with each other or with themselves.
    public var bulkProgress: BulkProgress?
    /// Dismissible results of the most recent bulk operation, bound to the
    /// original repositories so users can inspect failures and skipped work.
    public var bulkSummary: BulkOperationSummary?

    public var client: GitClient
    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private let scanner: (@Sendable ([URL]) async -> [Repo])?
    @ObservationIgnored private let clock: @Sendable () -> Date
    public func now() -> Date { clock() }

    /// The `gh` binary, if found on this machine — nil disables the PR/CI
    /// integration entirely (see `isGhAvailable`). Discovered once at
    /// launch; `gh` isn't expected to appear or disappear mid-session.
    public var gh: GhClient?
    /// Whether `gh` is both installed AND authenticated. Resolved once, off
    /// the main actor, by a one-shot `gh auth status` kicked off in `init`
    /// (nil `gh` short-circuits to `false` without spawning anything).
    /// Every PR/CI call site — `RepoDetailView.task(id:)` and `push()` —
    /// gates on this rather than re-checking auth per call, per the brief's
    /// "runs once per launch" contract for `isAuthenticated()`.
    public private(set) var isGhAvailable = false
    /// The active `gh` account's login (e.g. "sergiofarfan"), resolved by
    /// the same one-shot auth check in `init` that sets `isGhAvailable`;
    /// nil when `gh` is missing, unauthenticated, or the login can't be
    /// parsed. Rendered by `SidebarIdentityFooter`.
    public private(set) var ghAccountLogin: String?

    @ObservationIgnored private let watcher: RepoWatcher?
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

    private var autoFetchScheduler: AutoFetchScheduler?

    public init(
        preferences: UserDefaults = .standard,
        client: GitClient = GitClient(),
        scanner: (@Sendable ([URL]) async -> [Repo])? = nil,
        clock: @escaping @Sendable () -> Date = { Date() },
        watcher: RepoWatcher? = nil,
        events: AsyncStream<WatchEvent>? = nil,
        startServices: Bool = true
    ) {
        self.preferences = preferences
        let workflow = preferences.data(forKey: "workflow.v1").flatMap { try? JSONDecoder().decode(WorkflowSettings.self, from: $0) } ?? WorkflowSettings()
        self.workflowSettings = workflow
        self.client = workflow.gitPath == GitDefaults.gitPath ? client : GitClient(gitPath: workflow.gitPath)
        self.scanner = scanner
        self.clock = clock
        self.watcher = startServices ? (watcher ?? RepoWatcher()) : watcher
        let paths = preferences.stringArray(forKey: Self.trackedFolderPathsKey) ?? []
        trackedFolders = paths.map { URL(fileURLWithPath: $0) }
        isMenuBarExtraEnabled = preferences.bool(forKey: Self.menuBarEnabledKey)
        // Assigned before any other stored property below touches `self`
        // (Swift requires every `let` to be set before `self` escapes) —
        // the auth-check `Task` that uses this value is kicked off later,
        // once every property is initialized.
        gh = workflow.ghPath.isEmpty ? GhClient.discover() : GhClient(ghPath: workflow.ghPath)

        // Migration inputs are read unconditionally (cheap, and needed by
        // both the corrupt- and absent-key branches below); the legacy keys
        // themselves are never written again after this point.
        let legacyPinned = preferences.stringArray(forKey: Self.pinnedRepoIDsKey) ?? []
        let legacyAutoRebase = preferences.stringArray(forKey: Self.autoRebaseRepoIDsKey) ?? []

        if let data = preferences.data(forKey: Self.repoSettingsKey) {
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

        if let events = events ?? self.watcher?.events {
        watcherTask = Task { [weak self] in
            for await event in events {
                await self?.handle(event)
            }
        }

        // `self` is fully initialized at this point (same constraint the
        // watcher task above already satisfies), so it's safe to hand it to
        // the scheduler here.
        }
        if startServices {
            autoFetchScheduler = AutoFetchScheduler(model: self)
            autoFetchScheduler?.start()
        }

        // One-shot auth check, off the main actor while it awaits the `gh`
        // subprocess. Captures `gh` by value (a `Sendable` struct) rather
        // than reading `self.gh` inside the task, purely for clarity — it
        // reads identically either way since `gh` never changes after init.
        isGhAvailable = gh != nil
        if startServices {
            Task { [weak self] in
                self?.ghAccountLogin = await self?.gh?.activeAccountLogin()
            }
        }
    }

    public func updateWorkflowSettings(_ value: WorkflowSettings) {
        do {
            let validated = try value.validated()
            workflowSettings = validated
            preferences.set(try JSONEncoder().encode(validated), forKey: "workflow.v1")
            client = GitClient(gitPath: validated.gitPath)
            for vm in repos { vm.client = client }
            gh = validated.ghPath.isEmpty ? GhClient.discover() : GhClient(ghPath: validated.ghPath)
            isGhAvailable = gh != nil
            settingsError = nil
            Task { await refreshAllStatuses() }
        } catch { settingsError = error.localizedDescription }
    }

    isolated deinit {
        autoFetchScheduler?.stop()
        watcherTask?.cancel()
        watcher?.stop()
    }

    /// Repos matching `filterText` (name or branch, case-insensitive) that are
    /// pinned, alphabetical. Empty when no pinned repo matches.
    public var filteredPinned: [RepoViewModel] {
        filteredAndSorted(repos.filter { settings(for: $0.id).isPinned })
    }

    /// Unpinned repos partitioned by group, ordered by group name; excludes
    /// empty groups (a group exists only through its members).
    public var groupedSections: [(name: String, repos: [RepoViewModel])] {
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
    public var filteredUngrouped: [RepoViewModel] {
        filteredAndSorted(repos.filter { !settings(for: $0.id).isPinned && settings(for: $0.id).group == nil })
    }

    /// The settings for `id`, or all-default values if `id` has no entry
    /// (i.e. it has never had a non-default setting).
    public func settings(for id: String) -> RepoSettings {
        if let settings = repoSettingsByID[id] { return settings }
        // Keep existing path-keyed preferences when a symlinked root becomes canonical.
        return repoSettingsByID.first {
            URL(fileURLWithPath: $0.key).resolvingSymlinksInPath().standardizedFileURL.path == id
        }?.value ?? RepoSettings()
    }

    /// The view model `selectedRepoID` points at, or nil. Defensive:
    /// `selectedRepoID` can point at a repo that just disappeared (rescan
    /// pruned it, or `removeRepo` dropped it), so `first(where:)` returning
    /// nil is the "no selection" state, never a crash.
    public var selectedRepo: RepoViewModel? {
        guard let selectedRepoID else { return nil }
        return repos.first { $0.id == selectedRepoID }
    }

    /// Sorted unique non-nil group names currently assigned to any repo.
    /// Backs the settings sheet's Group picker; a later groups feature task
    /// reuses it for the sidebar.
    public var groupNames: [String] {
        Array(Set(repoSettingsByID.values.compactMap(\.group))).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    /// Sole write path for per-repo settings: mutates a copy, prunes it back
    /// out of the dictionary if it round-tripped to all-default, persists,
    /// and mirrors the auto-rebase flag onto the live view model (if any) so
    /// the next `push()` picks it up.
    public func updateSettings(for id: String, _ mutate: (inout RepoSettings) -> Void) {
        var s = settings(for: id)
        mutate(&s)
        if s.isDefault { repoSettingsByID.removeValue(forKey: id) } else { repoSettingsByID[id] = s }
        saveRepoSettings()
        repos.first { $0.id == id }?.autoRebaseOnRejectedPush = s.autoRebaseOnRejectedPush
    }

    private func saveRepoSettings() {
        if let data = try? JSONEncoder().encode(repoSettingsByID) {
            preferences.set(data, forKey: Self.repoSettingsKey)
        }
    }

    /// Toggles `id`'s pinned flag and persists it.
    public func togglePin(_ id: String) {
        updateSettings(for: id) { $0.isPinned.toggle() }
    }

    /// Toggles `id`'s auto-rebase flag, persists it, and updates the live
    /// view model's flag so the next Push picks it up.
    public func toggleAutoRebase(_ id: String) {
        updateSettings(for: id) { $0.autoRebaseOnRejectedPush.toggle() }
    }

    /// Assigns `id` to group `name` (or ungroups it if `nil`) and persists it.
    public func assignGroup(_ name: String?, to id: String) {
        updateSettings(for: id) { $0.group = name }
    }

    /// Drops a repo from the in-memory list only — it returns on the next
    /// rescan if still on disk. `hideRepo` is the persistent wrapper.
    public func removeRepo(_ id: String) {
        repos.removeAll { $0.id == id }
        if selectedRepoID == id {
            selectedRepoID = nil
        }
    }

    /// Hides a repo: persists the `isHidden` flag and drops it from the
    /// in-memory list (clearing the selection if it was selected). Unlike
    /// `removeRepo`, the repo does not return on the next rescan — restore
    /// it via the Folders menu's Hidden Repositories submenu. Never touches
    /// the filesystem.
    public func hideRepo(_ id: String) {
        updateSettings(for: id) { $0.isHidden = true }
        removeRepo(id)
    }

    /// Unhides a repo, persists, and kicks off a rescan so it reappears.
    public func unhideRepo(_ id: String) {
        updateSettings(for: id) { $0.isHidden = false }
        Task { await rescan() }
    }

    /// Unhides every hidden repo with a single follow-up rescan (calling
    /// `unhideRepo` in a loop would queue one redundant rescan per repo).
    public func unhideAllRepos() {
        for id in hiddenRepoIDs {
            updateSettings(for: id) { $0.isHidden = false }
        }
        Task { await rescan() }
    }

    /// The ids of every hidden repo, sorted case-insensitively by display
    /// name (the id's last path component). Backs the Folders menu's
    /// Hidden Repositories submenu.
    public var hiddenRepoIDs: [String] {
        repoSettingsByID.filter { $0.value.isHidden }.keys.sorted {
            let a = ($0 as NSString).lastPathComponent
            let b = ($1 as NSString).lastPathComponent
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
    }

    /// Concurrently refreshes every repo's status. `ProcessRunner`'s global
    /// semaphore bounds real subprocess concurrency, so no extra limiter here.
    public func refreshAllStatuses() async {
        await withTaskGroup(of: Void.self) { group in
            for vm in repos {
                group.addTask { await vm.refreshForExternalChange() }
            }
        }
    }

    /// Concurrently fetches every non-missing repo. See `runBulk` for the
    /// concurrency, guard, and error-reporting discipline shared with `pullAll`.
    public func fetchAll() async {
        await runBulk(progressVerb: "Fetching", summaryLabel: "Fetch All") { await $0.fetch() }
    }

    /// Concurrently pulls every non-missing repo. See `runBulk`.
    public func pullAll() async {
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
    /// retains each result for the dismissible `bulkSummary` and its details.
    private func runBulk(
        progressVerb: String,
        summaryLabel: String,
        action: @escaping @Sendable (RepoViewModel) async -> OperationResult
    ) async {
        guard bulkProgress == nil else { return }
        let targets = repos.filter { !$0.isMissing }
        guard !targets.isEmpty else { return }

        bulkSummary = nil
        bulkProgress = BulkProgress(verb: progressVerb, done: 0, total: targets.count)

        var results: [BulkOperationSummary.RepositoryResult] = []
        await withTaskGroup(of: BulkOperationSummary.RepositoryResult.self) { group in
            for vm in targets {
                let id = vm.id
                let name = vm.repo.name
                let path = vm.repo.path
                group.addTask {
                    .init(id: id, name: name, path: path, result: await action(vm))
                }
            }
            for await result in group {
                incrementBulkDone()
                results.append(result)
            }
        }
        let order = Dictionary(uniqueKeysWithValues: targets.enumerated().map { ($0.element.id, $0.offset) })
        bulkSummary = BulkOperationSummary(operation: summaryLabel, repositories: results.sorted {
            order[$0.id, default: 0] < order[$1.id, default: 0]
        })
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
    public func addFolders(_ urls: [URL]) {
        let existingPaths = Set(trackedFolders.map { $0.standardizedFileURL.path })
        let newFolders = urls.filter { !existingPaths.contains($0.standardizedFileURL.path) }
        guard !newFolders.isEmpty else { return }

        trackedFolders.append(contentsOf: newFolders.map { $0.resolvingSymlinksInPath().standardizedFileURL })
        saveTrackedFolders()
        Task { await rescan() }
    }

    /// Removes a tracked folder, persists, and kicks off a rescan.
    public func removeFolder(_ url: URL) {
        let targetPath = url.standardizedFileURL.path
        trackedFolders.removeAll { $0.standardizedFileURL.path == targetPath }
        saveTrackedFolders()
        Task { await rescan() }
    }

    /// Re-scans every tracked folder for git repos and rebuilds `repos`.
    ///
    /// Re-entrant calls are ignored while a scan is already running.
    public func rescan() async {
        if isScanning { pendingRescan = true; return }
        isScanning = true
        defer { isScanning = false }
        repeat {
            pendingRescan = false
            lastRescanAt = clock()
            let roots = trackedFolders
            let discovered: [Repo]
            if let scanner { discovered = await scanner(roots) }
            else { discovered = await RepositoryDiscovery.scan(roots: roots, gitPath: client.gitPath) }
            guard roots == trackedFolders else { pendingRescan = true; continue }
            var seen = Set<String>()
            let normalized = discovered.map { Repo(path: $0.path.resolvingSymlinksInPath().standardizedFileURL) }
            let visible = normalized.filter { seen.insert($0.id).inserted && !settings(for: $0.id).isHidden }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            let existing = Dictionary(uniqueKeysWithValues: repos.map { ($0.id, $0) })
            repos = visible.map { repo in
                let vm = existing[repo.id] ?? RepoViewModel(repo: repo, client: client, clock: clock)
                vm.autoRebaseOnRejectedPush = settings(for: repo.id).autoRebaseOnRejectedPush
                return vm
            }
            if let selectedRepoID, !repos.contains(where: { $0.id == selectedRepoID }) { self.selectedRepoID = nil }
            await withTaskGroup(of: Void.self) { group in
                for vm in repos { group.addTask { await vm.refreshContext() } }
            }
            watcher?.setWatched(roots: roots, repoPaths: repos.map(\.repo.path), contexts: repos.compactMap(\.context))
            await refreshAllStatuses()
        } while pendingRescan
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
    public func handle(_ event: WatchEvent) async {
        switch event {
        case .repoChanged(let url):
            let target = url.standardizedFileURL.path
            guard let vm = repos.first(where: { $0.repo.path.standardizedFileURL.path == target }) else {
                return
            }
            await vm.refreshForExternalChange()
            if selectedRepoID == vm.id, let gh { await vm.refreshPRInfo(using: gh, force: true) }

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
            if let lastRescanAt, clock().timeIntervalSince(lastRescanAt) < Self.rescanStormInterval {
                pendingRescan = true
                scheduleFollowUpRescan()
                return
            }
            await rescan()
        }
    }

    private func saveTrackedFolders() {
        let paths = trackedFolders.map { $0.path }
        preferences.set(paths, forKey: Self.trackedFolderPathsKey)
    }

    private func filteredAndSorted(_ list: [RepoViewModel]) -> [RepoViewModel] {
        list
            .filter { matchesFilter($0) }
            .sorted { $0.repo.name.localizedCaseInsensitiveCompare($1.repo.name) == .orderedAscending }
    }

    private func matchesFilter(_ vm: RepoViewModel) -> Bool {
        switch attentionFilter {
        case .all: break
        case .changes: guard (vm.status?.dirtyCount ?? 0) > 0 else { return false }
        case .conflicts: guard vm.status?.changes.contains(where: { $0.area == .unmerged }) == true else { return false }
        case .ahead: guard (vm.status?.ahead ?? 0) > 0 else { return false }
        case .behind: guard (vm.status?.behind ?? 0) > 0 else { return false }
        case .errors: guard vm.actionError != nil || vm.statusError != nil || vm.lastAutoFetchError != nil || vm.hostingError != nil else { return false }
        }
        guard !filterText.isEmpty else { return true }
        if vm.repo.name.localizedCaseInsensitiveContains(filterText) { return true }
        if let branch = vm.status?.branch, branch.localizedCaseInsensitiveContains(filterText) { return true }
        return false
    }
}
