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
        .inspector(isPresented: $vm.isDiffPresented) {
            DiffView(vm: vm)
                .inspectorColumnWidth(min: 320, ideal: 460, max: 800)
        }
        .task(id: vm.id) {
            // Clear any diff left open from a prior visit to this repo, so
            // switching repos never leaves a stale (or just surprising)
            // diff inspector open against the newly selected one.
            vm.diffTarget = nil
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
        // `isGhAvailable` resolves asynchronously (an early `gh auth
        // status` check) and typically settles AFTER `.task(id: vm.id)`
        // has already run and skipped the PR refresh for the repo selected
        // at launch — so that first repo would show no badge until a
        // branch/repo change or push. Re-run the same guarded refresh once
        // availability flips true. `refreshPRInfo`'s own TTL + in-flight
        // guard de-dupes against the other two tasks, so this is harmless
        // even when it's not the one that actually needed to fire.
        .task(id: model.isGhAvailable) {
            if model.isGhAvailable, let gh = model.gh {
                await vm.refreshPRInfo(using: gh)
            }
        }
    }
}
