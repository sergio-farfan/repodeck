import SwiftUI

struct RepoListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            SidebarHeader()
            SidebarFilterField(text: $model.filterText)
            repoList
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { SidebarIdentityFooter() }
        .background(Theme.sidebarBackground(for: colorScheme).ignoresSafeArea())
    }

    private var repoList: some View {
        @Bindable var model = model

        return List(selection: $model.selectedRepoID) {
            if !model.filteredPinned.isEmpty {
                Section("Pinned") {
                    ForEach(model.filteredPinned) { vm in
                        RepoRowView(vm: vm)
                    }
                }
            }

            ForEach(model.groupedSections, id: \.name) { section in
                Section(section.name) {
                    ForEach(section.repos) { vm in
                        RepoRowView(vm: vm)
                    }
                }
            }

            if !model.filteredUngrouped.isEmpty {
                Section("Repositories") {
                    ForEach(model.filteredUngrouped) { vm in
                        RepoRowView(vm: vm)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }
}

private struct SidebarHeader: View {
    @Environment(\.theme) private var theme
    var body: some View {
        HStack {
            Text("RepoDeck")
                .font(theme.ui(18, weight: .bold))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }
}

/// The sidebar's repo filter, replacing `.searchable` so it renders below
/// the app title (a top `safeAreaInset` cannot be ordered above the
/// `.sidebar`-placement search field). Same magnifying-glass + plain
/// TextField shape as `HistoryListView.searchBar`, in a rounded fill.
private struct SidebarFilterField: View {
    @Binding var text: String
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(theme.callout)

            TextField("Filter repositories", text: $text)
                .textFieldStyle(.plain)
                .font(theme.callout)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }
}
