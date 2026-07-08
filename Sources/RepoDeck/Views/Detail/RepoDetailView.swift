import SwiftUI

/// Container for the selected repo's detail pane: an `ErrorBanner` for the
/// most recent action failure, a commit box, sync controls (pull/push/
/// fetch), the changes list, and history (Task 15).
struct RepoDetailView: View {
    let vm: RepoViewModel

    var body: some View {
        @Bindable var vm = vm

        VStack(alignment: .leading, spacing: 0) {
            ErrorBanner(error: $vm.actionError)

            CommitBoxView(vm: vm)

            SyncControlsView(vm: vm)

            Divider()

            ChangesListView(vm: vm)

            Divider()

            Text("History")
                .font(.headline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .navigationTitle(vm.repo.name)
        .task(id: vm.id) {
            await vm.refreshLog()
        }
    }
}
