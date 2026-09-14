import AppKit
import RepoDeckCore
import RepoDeckKit
import SwiftUI

struct RepositoryWorkspaceView: View {
    @Environment(AppModel.self) private var model
    let vm: RepoViewModel
    @State private var pending: WorkspaceAction?
    @State private var rename = ""
    @State private var upstream = ""

    private var workspace: RepositoryWorkspaceModel { vm.workspace }
    private var service: RepositoryService { RepositoryService(gitPath: vm.client.gitPath) }

    var body: some View {
        @Bindable var workspace = workspace
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let error = workspace.error {
                    RepositoryFailureBanner(vm: vm, failure: OperationFailure(message: error, command: "Load branches and worktrees")) { workspace.error = nil }
                }
                GroupBox("Create branch") {
                    HStack {
                        TextField("New branch name", text: $workspace.branchName)
                        TextField("Starting revision (optional)", text: $workspace.startPoint)
                        Button("Create & Switch") {
                            let name = workspace.branchName
                            let start = workspace.startPoint.isEmpty ? nil : workspace.startPoint
                            confirm("Create and switch to \(name) from \(start ?? "HEAD")") {
                                try await service.createBranch(name: name, startPoint: start, in: vm.repo.path)
                                if let start, start.hasPrefix("refs/remotes/") {
                                    try await service.setUpstream(String(start.dropFirst("refs/remotes/".count)), for: name, in: vm.repo.path)
                                }
                            }
                        }.disabled(workspace.branchName.isEmpty)
                    }.padding(8)
                }
                GroupBox("Branches") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            TextField("New name for Rename", text: $rename)
                            TextField("Upstream for Set Tracking (e.g. origin/main)", text: $upstream)
                        }
                        ForEach(workspace.branches) { branch in
                            HStack {
                                Image(systemName: branch.isCurrent ? "checkmark.circle.fill" : "arrow.triangle.branch")
                                    .accessibilityLabel(branch.isCurrent ? "Current branch" : "Branch")
                                VStack(alignment: .leading) {
                                    Text(branch.name).fontWeight(branch.isCurrent ? .semibold : .regular)
                                    if let tracking = branch.upstream { Text("Tracks \(tracking)").font(.caption).foregroundStyle(.secondary) }
                                    if let path = branch.worktreePath, path != vm.repo.path.path {
                                        Text("In \(path)").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Menu("Actions") {
                                    if branch.isRemote {
                                        Button("Create Tracking Branch…") {
                                            workspace.startPoint = branch.fullRef
                                            workspace.branchName = branch.name.split(separator: "/").dropFirst().joined(separator: "/")
                                        }
                                    } else {
                                        Button("Switch") { confirm("Switch to \(branch.name)") { try await service.switchBranch(branch.name, expected: branch, in: vm.repo.path) } }
                                            .disabled(branch.isCurrent || branch.worktreePath != nil)
                                        Button("Rename to \(rename.isEmpty ? "new name" : rename)") {
                                            let name = rename
                                            confirm("Rename \(branch.name) to \(name)") { try await service.renameBranch(branch.name, to: name, expected: branch, in: vm.repo.path) }
                                        }.disabled(rename.isEmpty)
                                        Button("Delete Merged Branch", role: .destructive) {
                                            confirm("Delete merged branch \(branch.name)") { try await service.deleteBranch(branch.name, expected: branch, in: vm.repo.path) }
                                        }.disabled(branch.worktreePath != nil || branch.isCurrent)
                                        Button("Set Tracking") {
                                            let tracking = upstream
                                            confirm("Set \(branch.name) to track \(tracking)") { try await service.setUpstream(tracking, for: branch.name, expected: branch, in: vm.repo.path) }
                                        }.disabled(upstream.isEmpty)
                                        Button("Remove Tracking") {
                                            confirm("Remove tracking from \(branch.name)") { try await service.setUpstream(nil, for: branch.name, expected: branch, in: vm.repo.path) }
                                        }.disabled(branch.upstream == nil)
                                    }
                                    Divider()
                                    Button("Merge into Current Branch") {
                                        confirm("Merge \(branch.name) into \(vm.status?.branch ?? "HEAD")") { try await service.merge(branch.fullRef, expected: branch, in: vm.repo.path) }
                                    }.disabled(branch.isCurrent)
                                    Button("Rebase Current Branch onto This") {
                                        confirm("Rebase \(vm.status?.branch ?? "HEAD") onto \(branch.name); this rewrites local commits") {
                                            try await service.rebase(onto: branch.fullRef, expected: branch, in: vm.repo.path)
                                        }
                                    }.disabled(branch.isCurrent)
                                }.accessibilityLabel("Actions for \(branch.name)")
                            }
                            Divider()
                        }
                    }.padding(8)
                }
                GroupBox("Worktrees") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            TextField("New worktree directory (absolute path)", text: $workspace.worktreePath)
                            Button("Choose…") { chooseWorktreeDirectory() }
                        }
                        HStack {
                            TextField("Branch name", text: $workspace.branchName)
                            Button("Use Existing Branch") { createWorktree(newBranch: false) }
                            Button("Create New Branch") { createWorktree(newBranch: true) }
                        }.disabled(workspace.branchName.isEmpty || !workspace.worktreePath.hasPrefix("/"))
                        ForEach(workspace.worktrees) { worktree in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(worktree.branch ?? (worktree.isBare ? "Bare repository" : "Detached HEAD"))
                                    Text(worktree.path.path).font(.caption).textSelection(.enabled)
                                    if worktree.isLocked { Label("Locked", systemImage: "lock") }
                                }
                                Spacer()
                                Button("Open") { open(worktree.path) }.disabled(worktree.isBare || worktree.isPrunable)
                                Button("Remove…", role: .destructive) {
                                    confirm("Remove clean worktree at \(worktree.path.path)") {
                                        try await service.removeWorktree(worktree, in: vm.repo.path)
                                    }
                                }.disabled(worktree.isMain || worktree.isLocked || worktree.isBare || worktree.path.path == vm.id)
                            }
                            Divider()
                        }
                    }.padding(8)
                }
            }.padding()
        }
        .disabled(vm.isBusy)
        .task(id: vm.refreshRevision) { await workspace.refresh(using: vm) }
        .confirmationDialog(pending?.title ?? "Repository action", isPresented: Binding(
            get: { pending != nil }, set: { if !$0 { pending = nil } }
        ), titleVisibility: .visible) {
            if let action = pending {
                Button("Confirm") {
                    pending = nil
                    Task {
                        await vm.performAction(refreshingLog: true, refreshingStashes: true, expectedIdentity: action.identity, action.run)
                        await workspace.refresh(using: vm)
                        await model.rescan()
                    }
                }
            }
        } message: { Text(vm.repo.path.path) }
    }

    private func confirm(_ title: String, run: @escaping @MainActor () async throws -> Void) {
        pending = WorkspaceAction(title: title, identity: vm.operationIdentity, run: run)
    }

    private func chooseWorktreeDirectory() {
        let panel = NSSavePanel()
        panel.title = "Choose a new worktree directory"
        panel.nameFieldStringValue = vm.repo.name + "-worktree"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let path = panel.url { workspace.worktreePath = path.path }
    }

    private func createWorktree(newBranch: Bool) {
        let path = URL(fileURLWithPath: workspace.worktreePath)
        let branch = workspace.branchName
        confirm("Create worktree at \(path.path) using \(newBranch ? "new" : "existing") branch \(branch)") {
            try await service.createWorktree(at: path, branch: branch, createBranch: newBranch, in: vm.repo.path)
        }
    }

    private func open(_ path: URL) {
        model.addFolders([path])
        Task { await model.rescan(); model.selectedRepoID = path.resolvingSymlinksInPath().standardizedFileURL.path }
    }
}

private struct WorkspaceAction {
    let title: String
    let identity: RepositoryOperationIdentity
    let run: @MainActor () async throws -> Void
}

struct CommitGraphView: View {
    let vm: RepoViewModel
    @State private var showSearch = false

    var body: some View {
        @Bindable var workspace = vm.workspace
        VStack(spacing: 0) {
            HStack {
                Toggle("All branches and tags", isOn: $workspace.allBranches)
                    .onChange(of: workspace.allBranches) {
                        workspace.graph = []
                        Task { await workspace.refresh(using: vm) }
                    }
                Spacer()
                Toggle("Search", isOn: $showSearch).toggleStyle(.button)
                Button("Refresh") { Task { await workspace.refresh(using: vm) } }
            }.padding(10)
            if let error = workspace.error {
                RepositoryFailureBanner(vm: vm, failure: OperationFailure(message: error, command: "Load history")) { workspace.error = nil }
            }
            if showSearch { HistoryListView(vm: vm) }
            else {
                let lanes = GraphLaneRow.layout(workspace.graph)
                let graphWidth = CGFloat(max(2, lanes.map(\.width).max() ?? 2) * 16 + 12)
                ScrollViewReader { scroll in
                List(selection: $workspace.selectedCommit) {
                    ForEach(Array(workspace.graph.enumerated()), id: \.element.id) { index, node in
                        HStack(spacing: 8) {
                            GraphLaneView(row: lanes[index]).frame(width: graphWidth, height: 44).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(node.commit.subject).lineLimit(1)
                                Text("\(node.commit.shortHash) · \(node.commit.author) · \(node.commit.refs.joined(separator: ", "))")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Menu("Parents (\(node.parents.count))") {
                                ForEach(node.parents, id: \.self) { oid in
                                    Button(String(oid.prefix(10)) + (workspace.graph.contains { $0.id == oid } ? "" : " (load history)")) {
                                        Task {
                                            while !workspace.graph.contains(where: { $0.id == oid }), workspace.hasMoreHistory, !workspace.isLoading, !Task.isCancelled {
                                                let oldCount = workspace.graph.count
                                                await workspace.loadMore(using: vm)
                                                if workspace.graph.count <= oldCount { break }
                                            }
                                            if let parent = workspace.graph.first(where: { $0.id == oid }) {
                                                workspace.selectedCommit = oid
                                                await vm.showDiff(.commit(parent.commit))
                                            } else { workspace.error = "This parent is outside the current history. Try all branches or refresh after fetching." }
                                        }
                                    }
                                }
                            }.fixedSize().disabled(node.parents.isEmpty)
                            Button("Diff") { Task { await vm.showDiff(.commit(node.commit)) } }
                                .accessibilityLabel("View diff for \(node.commit.subject)")
                        }.tag(node.id).id(node.id)
                        .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
                        .listRowSeparator(.hidden)
                    }
                }
                .onChange(of: workspace.selectedCommit) { if let selected = workspace.selectedCommit { scroll.scrollTo(selected, anchor: .center) } }
                }
                if workspace.graph.isEmpty && !workspace.isLoading {
                    Text("No commits in this history view").foregroundStyle(.secondary).padding(10)
                }
                if workspace.hasMoreHistory {
                    Button(workspace.isLoading ? "Loading…" : "Load 100 More Commits") {
                        Task { await workspace.loadMore(using: vm) }
                    }.disabled(workspace.isLoading).padding(8)
                }
            }
        }.task(id: vm.refreshRevision) { await workspace.refresh(using: vm) }
    }
}

private struct GraphLaneView: View {
    let row: GraphLaneRow
    var body: some View {
        Canvas { context, size in
            func point(_ column: Int, _ y: CGFloat) -> CGPoint { CGPoint(x: CGFloat(column * 16 + 8), y: y) }
            var path = Path()
            for column in row.incomingColumns {
                path.move(to: point(column, 0)); path.addLine(to: point(column, size.height / 2))
            }
            for edge in row.edges {
                path.move(to: point(edge.from, size.height / 2))
                path.addLine(to: point(edge.to, size.height))
            }
            context.stroke(path, with: .color(.secondary), lineWidth: 1.5)
            let center = point(row.column, size.height / 2)
            context.fill(Path(ellipseIn: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8)), with: .color(.accentColor))
        }
    }
}
