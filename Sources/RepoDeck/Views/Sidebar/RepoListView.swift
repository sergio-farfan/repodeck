import SwiftUI

struct RepoListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        List(selection: $model.selectedRepoID) {
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
        .searchable(text: $model.filterText, placement: .sidebar, prompt: "Filter repositories")
    }
}
