import AppKit
import RepoDeckCore
import RepoDeckKit
import SwiftUI

struct ConflictWorkspaceView: View {
    @Environment(AppModel.self) private var model
    let vm: RepoViewModel
    @State private var pendingAbort: RepositoryOperationIdentity?
    @State private var pendingAbortLabel = ""
    @State private var pendingReloadPath: String?
    @State private var pendingStage: ExternalResolutionPreview?

    private var conflicts: [FileChange] { vm.status?.changes.filter { $0.area == .unmerged } ?? [] }

    var body: some View {
        @Bindable var workspace = vm.workspace
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(vm.operationState.label, systemImage: "arrow.triangle.merge")
                Spacer()
                Button("Continue") {
                    let identity = vm.operationIdentity
                    Task { await vm.performAction(refreshingLog: true, refreshingStashes: true, allowInProgress: true, expectedIdentity: identity) {
                        try await RepositoryService(gitPath: vm.client.gitPath).continueOperation(in: vm.repo.path)
                    } }
                }.disabled(!conflicts.isEmpty || vm.operationState == .normal || vm.operationState == .unsupported || vm.isBusy || workspace.isLoadingConflict)
                Button("Abort…", role: .destructive) {
                    pendingAbortLabel = vm.operationState.label
                    pendingAbort = vm.operationIdentity
                }
                    .disabled(vm.operationState == .normal || vm.operationState == .unsupported || vm.isBusy)
            }
            HStack {
                Picker("Conflicted file", selection: Binding(get: { workspace.selectedConflict ?? "" }, set: { path in
                    guard !path.isEmpty, !vm.isBusy else { return }
                    Task { await workspace.loadConflict(path, using: vm) }
                })) {
                    Text("Select a file").tag("")
                    ForEach(conflicts) { file in Text(file.path).tag(file.path) }
                }.disabled(vm.isBusy)
                Button("Reload from Disk…") { pendingReloadPath = workspace.selectedConflict }
                    .disabled(vm.isBusy || workspace.isLoadingConflict || workspace.selectedConflict == nil)
            }
            if let error = workspace.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if workspace.conflictChangedExternally {
                Label("This conflict changed on disk. Your draft is retained. Reload before saving or marking resolved.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            if workspace.isLoadingConflict {
                ProgressView("Loading conflict…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let document = workspace.conflictDocument, workspace.selectedConflict == document.path {
                if let reason = document.unavailableReason {
                    Text(reason)
                    HStack {
                        Button("Open in Configured Editor") { openExternal(document.path) }
                        Button("Open Terminal") { model.openInTerminal(vm.repo.path, repoID: vm.id) }
                    }.disabled(vm.isBusy)
                    Button("Mark Resolved (Stage Whole File)…") {
                        guard let change = conflicts.first(where: { $0.path == document.path }) else { return }
                        pendingStage = ExternalResolutionPreview(change: change, identity: vm.operationIdentity)
                    }.disabled(vm.isBusy || workspace.conflictChangedExternally || !conflicts.contains(where: { $0.path == document.path }))
                    Text("Resolve this file with your editor or Git’s configured mergetool, then reload from disk and mark it resolved. Staging records the entire file, including a resolved deletion.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    HStack(alignment: .top, spacing: 8) {
                        source("Base", document.base)
                        source(currentLabel, document.current)
                        source(incomingLabel, document.incoming)
                    }.frame(maxHeight: 220)
                    Text("Result").font(.headline)
                    TextEditor(text: $workspace.resolution)
                        .font(.system(.body, design: .monospaced))
                        .accessibilityLabel("Editable conflict resolution for \(document.path)")
                        .border(Color.secondary.opacity(0.3))
                    HStack {
                        Button("Save Result") { Task { await workspace.saveResolution(using: vm) } }
                            .disabled(vm.isBusy || workspace.conflictChangedExternally)
                        Button("Mark Resolved") { Task { await workspace.markResolved(using: vm) } }
                            .disabled(vm.isBusy || workspace.conflictChangedExternally || workspace.resolution != document.workingText)
                        Text(workspace.resolution == document.workingText ? "Saved on disk; Mark Resolved stages this file." : "Unsaved edits")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else if conflicts.isEmpty {
                ContentUnavailableView("No Conflicted Files", systemImage: "checkmark.circle", description: Text("Continue the current operation once every resolution is staged."))
            } else { Spacer() }
        }
        .padding()
        .task(id: vm.refreshRevision) { await workspace.refresh(using: vm) }
        .confirmationDialog("Abort \(pendingAbortLabel)?", isPresented: Binding(
            get: { pendingAbort != nil }, set: { if !$0 { pendingAbort = nil } }
        ), titleVisibility: .visible) {
            Button("Abort Operation", role: .destructive) {
                guard let identity = pendingAbort else { return }
                pendingAbort = nil
                Task { await vm.performAction(refreshingLog: true, refreshingStashes: true, allowInProgress: true, expectedIdentity: identity) {
                    try await RepositoryService(gitPath: vm.client.gitPath).abortOperation(in: vm.repo.path)
                } }
            }
        } message: { Text("Git will restore the state from before the operation in \(vm.repo.path.path). Saved conflict resolutions may be replaced.") }
        .confirmationDialog("Replace this resolution draft with the current file on disk?", isPresented: Binding(
            get: { pendingReloadPath != nil }, set: { if !$0 { pendingReloadPath = nil } }
        ), titleVisibility: .visible) {
            Button("Reload and Replace Draft", role: .destructive) {
                guard let path = pendingReloadPath, workspace.selectedConflict == path, !vm.isBusy else { return }
                pendingReloadPath = nil
                Task {
                    await vm.refreshStatus()
                    await workspace.loadConflict(path, using: vm, reload: true)
                }
            }
        } message: { Text(pendingReloadPath ?? "") }
        .confirmationDialog("Stage this entire file as resolved?", isPresented: Binding(
            get: { pendingStage != nil }, set: { if !$0 { pendingStage = nil } }
        ), titleVisibility: .visible) {
            Button("Stage Whole File") {
                guard let action = pendingStage else { return }
                pendingStage = nil
                Task { await stageExternalResolution(action) }
            }
        } message: {
            Text("\(pendingStage?.change.path ?? "")\n\nThis stages the file’s current contents, or its deletion if it is missing. Confirm only after resolving it in your external tool.")
        }
    }

    private func source(_ title: String, _ text: String?) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.headline)
            ScrollView([.horizontal, .vertical]) {
                Text(text ?? "File absent at this stage")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).border(Color.secondary.opacity(0.3))
        }
    }

    private func openExternal(_ path: String) {
        let url = vm.repo.path.appendingPathComponent(path)
        model.openInEditor(url, repoID: vm.id)
    }

    private var currentLabel: String {
        vm.operationState == .rebase ? "Rebase target (ours)" : "Current branch (ours)"
    }

    private var incomingLabel: String {
        switch vm.operationState {
        case .rebase: "Commit being replayed (theirs)"
        case .cherryPick: "Commit being applied (theirs)"
        case .revert: "Version being restored (theirs)"
        default: "Incoming (theirs)"
        }
    }

    private func stageExternalResolution(_ action: ExternalResolutionPreview) async {
        let workspace = vm.workspace
        let path = action.change.path
        guard !vm.isBusy, !workspace.isLoadingConflict, !workspace.conflictChangedExternally,
              workspace.selectedConflict == path, workspace.conflictDocument?.path == path,
              conflicts.contains(where: { $0.path == path }) else {
            workspace.error = "The selected conflict changed. Reload it before marking it resolved."
            return
        }
        let result = await vm.performAction(allowInProgress: true, expectedIdentity: action.identity) {
            let current = try await vm.client.status(in: vm.repo.path)
            guard current.changes.contains(where: { $0.path == path && $0.area == .unmerged }) else {
                throw GitError(command: "git add", exitCode: -1,
                               stderr: "This file is no longer an unresolved conflict. Review the refreshed changes before staging it.")
            }
            try await vm.client.stage([path], in: vm.repo.path)
        }
        if result == .succeeded, workspace.selectedConflict == path {
            workspace.selectedConflict = nil
            workspace.conflictDocument = nil
            workspace.resolution = ""
            workspace.conflictChangedExternally = false
        }
        await workspace.refresh(using: vm)
    }
}

private struct ExternalResolutionPreview {
    let change: FileChange
    let identity: RepositoryOperationIdentity
}
