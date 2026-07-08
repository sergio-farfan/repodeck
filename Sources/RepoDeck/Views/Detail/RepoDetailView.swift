import SwiftUI

/// Container for the selected repo's detail pane: an inline error surface
/// (replaced by `ErrorBanner` in Task 14), the changes list (this task), a
/// commit box (Task 13), and history (Task 15).
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

            ChangesListView(vm: vm)

            Divider()

            Text("History")
                .font(.headline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .navigationTitle(vm.repo.name)
    }
}
