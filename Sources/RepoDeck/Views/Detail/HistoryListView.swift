import SwiftUI

/// Commit history section: a header with the commit count, then a compact
/// list of `CommitRow`s populated from `vm.commits` (kept fresh by
/// `RepoViewModel.refreshLog()`). Deliberate v1 scope: no graph, no
/// pagination — the 100-commit log limit from `GitClient` is enough.
struct HistoryListView: View {
    @Environment(\.theme) private var theme
    let vm: RepoViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if vm.commits.isEmpty {
                Text("No commits yet")
                    .font(theme.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            } else {
                List(vm.commits) { commit in
                    CommitRow(commit: commit)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        Text("History (\(vm.commits.count))")
            .font(theme.title)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
    }
}
