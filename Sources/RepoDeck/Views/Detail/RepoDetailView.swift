import RepoDeckCore
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
    /// Fraction of the whole detail pane given to the existing content when
    /// the command-runner pane (below it) is visible; the runner gets the
    /// rest. Same single-global-value reasoning as `changesFraction`.
    @AppStorage("detail.commandFraction") private var commandFraction: Double = 0.7

    var body: some View {
        @Bindable var vm = vm

        // Always route through `VerticalSplit`, toggling `isSplit`, so the
        // command pane docks/undocks by collapsing the split rather than by
        // moving `detailContent` in and out of the tree — which would reset
        // the Changes/History scroll positions and other `@State` on every
        // toggle (see `VerticalSplit`'s note).
        VerticalSplit(fraction: $commandFraction, isSplit: vm.isCommandPaneVisible) {
            detailContent
        } bottom: {
            CommandRunnerView(vm: vm)
        }
        .navigationTitle(vm.repo.name)
        .inspector(isPresented: $vm.isDiffPresented) {
            DiffView(vm: vm)
                .inspectorColumnWidth(min: 320, ideal: 460, max: 800)
        }
        .task(id: vm.id) {
            await vm.refreshForExternalChange()
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

    /// The pre-existing detail pane content (banners, commit box, sync
    /// controls, the Changes/History split) — factored out so it renders
    /// identically whether or not the command-runner pane is docked below
    /// it, instead of being duplicated across both branches of `body`.
    @ViewBuilder
    private var detailContent: some View {
        @Bindable var vm = vm

        VStack(alignment: .leading, spacing: 0) {
            ErrorBanner(error: $vm.actionError)
            NoticeBanner(notice: $vm.actionNotice)
            SyncControlsView(vm: vm)
            if vm.operationState != .normal {
                HStack {
                    Label(vm.operationState.label, systemImage: "exclamationmark.triangle")
                    Spacer()
                    Button("Open Conflicts") { vm.selectedSection = .conflicts }
                }.padding(10)
            }
            ViewThatFits(in: .horizontal) {
                workspacePicker.pickerStyle(.segmented).fixedSize()
                workspacePicker.pickerStyle(.menu).fixedSize()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            switch vm.selectedSection {
            case .changes:
                CommitBoxView(vm: vm)
                ChangesListView(vm: vm)
            case .history: CommitGraphView(vm: vm)
            case .branches: RepositoryWorkspaceView(vm: vm)
            case .conflicts: ConflictWorkspaceView(vm: vm)
            case .reviews:
                ReviewsView(repoURL: vm.repo.path, gitPath: vm.client.gitPath,
                            ghPath: model.workflowSettings.ghPath.isEmpty ? nil : model.workflowSettings.ghPath,
                            glabPath: model.workflowSettings.glabPath.isEmpty ? nil : model.workflowSettings.glabPath,
                            refreshRevision: vm.refreshRevision,
                            onCheckout: { path in
                    model.addFolders([path])
                    Task { await model.rescan(); model.selectedRepoID = path.resolvingSymlinksInPath().standardizedFileURL.path }
                })
                .id(vm.id)
            }
        }
    }

    private var workspacePicker: some View {
        @Bindable var vm = vm
        return Picker("Workspace", selection: $vm.selectedSection) {
            ForEach(RepositorySection.allCases, id: \.self) { section in
                Text(section == .branches ? "Branches & Worktrees" : section.rawValue).tag(section)
            }
        }
    }
}
