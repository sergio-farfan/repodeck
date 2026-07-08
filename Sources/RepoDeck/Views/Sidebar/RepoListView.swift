import SwiftUI

struct RepoListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        List(selection: $model.selectedRepoID) {
            Section("Repositories") {
                ForEach(model.repos) { vm in
                    RepoRowView(vm: vm)
                }
            }
        }
        .listStyle(.sidebar)
    }
}
