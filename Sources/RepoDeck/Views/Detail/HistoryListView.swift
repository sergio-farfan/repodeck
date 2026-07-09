import RepoDeckKit
import SwiftUI

/// Commit history section: a header with the commit count, a search field +
/// scope picker for filtering by message/author/path/content, then a compact
/// list of `CommitRow`s populated from `vm.commits` (kept fresh by
/// `RepoViewModel.refreshLog()`/`scheduleHistorySearch()`). Deliberate v1
/// scope: no graph, no pagination — the 100-commit log limit from
/// `GitClient` is enough.
struct HistoryListView: View {
    @Environment(\.theme) private var theme
    let vm: RepoViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            searchBar

            if vm.commits.isEmpty {
                emptyState
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

    @ViewBuilder
    private var searchBar: some View {
        @Bindable var vm = vm

        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(theme.callout)

            TextField("Search history", text: $vm.historyQuery)
                .textFieldStyle(.plain)
                .font(theme.callout)
                .onChange(of: vm.historyQuery) {
                    vm.scheduleHistorySearch()
                }

            Picker("Search field", selection: $vm.historyField) {
                Text("Message").tag(HistorySearchField.message)
                Text("Author").tag(HistorySearchField.author)
                Text("File").tag(HistorySearchField.path)
                Text("Content").tag(HistorySearchField.content)
            }
            .labelsHidden()
            .font(theme.callout)
            .fixedSize()
            .onChange(of: vm.historyField) {
                Task { await vm.refreshLog() }
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var emptyState: some View {
        let isSearching = !vm.historyQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        Text(isSearching ? "No matching commits" : "No commits yet")
            .font(theme.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
    }
}
