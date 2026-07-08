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
    /// Reserved for later action tasks (commit/push/pull); `refreshStatus`
    /// never touches this — refresh is a passive, always-allowed operation.
    var isBusy = false

    /// Coalescing pair: only one `git status` runs per repo at a time. A call
    /// that arrives mid-refresh is folded into a single trailing refresh
    /// instead of piling up concurrent invocations.
    private var refreshInFlight = false
    private var refreshQueued = false

    var id: String { repo.id }

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
}
