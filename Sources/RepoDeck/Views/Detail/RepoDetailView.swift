import SwiftUI

/// Container for the selected repo's detail pane: an `ErrorBanner` for the
/// most recent action failure, a `NoticeBanner` for info-level outcomes
/// (e.g. auto-rebase before push), a commit box, sync controls (pull/push/
/// fetch), the changes list, and the commit history.
struct RepoDetailView: View {
    @Environment(AppModel.self) private var model
    let vm: RepoViewModel

    /// Fraction of the Changes/History region given to Changes. A single
    /// global value (not per-repo); `RepoDetailView` is a plain `View`, so
    /// `@AppStorage` works here (unlike in the `@Observable` view models).
    @AppStorage("detail.changesFraction") private var changesFraction: Double = 0.5

    var body: some View {
        @Bindable var vm = vm

        VStack(alignment: .leading, spacing: 0) {
            ErrorBanner(error: $vm.actionError)
            NoticeBanner(notice: $vm.actionNotice)

            CommitBoxView(vm: vm)

            SyncControlsView(vm: vm)

            Divider()

            VerticalSplit(fraction: $changesFraction) {
                ChangesListView(vm: vm)
            } bottom: {
                HistoryListView(vm: vm)
            }
        }
        .navigationTitle(vm.repo.name)
        .task(id: vm.id) {
            await vm.refreshLog()
            await vm.refreshStashes()
            if model.isGhAvailable, let gh = model.gh {
                await vm.refreshPRInfo(using: gh)
            }
        }
        // Re-evaluate the PR badge when the selected repo's branch changes
        // in place (an external `git checkout` the watcher picked up) —
        // `.task(id: vm.id)` only fires on repo switch, so without this the
        // badge would keep showing the previous branch's PR. `refreshPRInfo`
        // itself drops the wrong-branch cache and bypasses the TTL.
        .task(id: vm.status?.branch) {
            if model.isGhAvailable, let gh = model.gh {
                await vm.refreshPRInfo(using: gh)
            }
        }
    }
}
