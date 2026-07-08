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

    var trackedFolders: [URL]
    var repos: [RepoViewModel] = []
    var isScanning = false
    var selectedRepoID: String?

    let client = GitClient()

    init() {
        let paths = UserDefaults.standard.stringArray(forKey: Self.trackedFolderPathsKey) ?? []
        trackedFolders = paths.map { URL(fileURLWithPath: $0) }
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
    }

    private func saveTrackedFolders() {
        let paths = trackedFolders.map { $0.path }
        UserDefaults.standard.set(paths, forKey: Self.trackedFolderPathsKey)
    }
}
