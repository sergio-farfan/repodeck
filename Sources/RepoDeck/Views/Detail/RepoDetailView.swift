import SwiftUI

/// Container for the selected repo's detail pane: an inline error surface
/// (replaced by `ErrorBanner` in Task 14), a commit box (this task), the
/// changes list (Task 12), and history (Task 15).
struct RepoDetailView: View {
    let vm: RepoViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let actionError = vm.actionError {
                Text(actionError.localizedDescription)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
            }

            CommitBoxView(vm: vm)

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
