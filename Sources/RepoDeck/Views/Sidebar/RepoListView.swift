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

            Section("Repositories") {
                ForEach(model.filteredUnpinned) { vm in
                    RepoRowView(vm: vm)
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $model.filterText, placement: .sidebar, prompt: "Filter repositories")
    }
}
