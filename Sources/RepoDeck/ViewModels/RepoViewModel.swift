import Foundation
import Observation
import RepoDeckKit

/// Skeleton view model for a single tracked repo.
///
/// Task 10 adds status/refresh logic; keep this minimal until then.
@MainActor
@Observable
final class RepoViewModel: @MainActor Identifiable {
    let repo: Repo
    let client: GitClient

    var id: String { repo.id }

    init(repo: Repo, client: GitClient) {
        self.repo = repo
        self.client = client
    }
}
