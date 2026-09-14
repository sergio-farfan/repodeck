import RepoDeckCore
import RepoDeckKit
import SwiftUI

/// Adapts sync controls and repository status to the available detail width.
struct SyncControlsView: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var model
    let vm: RepoViewModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                syncButtons.fixedSize()
                auxiliaryButtons.fixedSize()
                Spacer(minLength: 8)
                status
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) { syncButtons; Spacer() }
                HStack(spacing: 12) { auxiliaryButtons; Spacer() }
                status.frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(10)
    }

    private var syncButtons: some View {
        HStack(spacing: 12) {
            Button {
                Task { await vm.pull() }
            } label: {
                Label("Pull", systemImage: "arrow.down")
            }
            .disabled(vm.isBusy || vm.isRunningCommand || vm.operationState != .normal)

            Button {
                Task { await vm.push(using: model.isGhAvailable ? model.gh : nil) }
            } label: {
                Label("Push", systemImage: "arrow.up")
            }
            .disabled(vm.isBusy || vm.isRunningCommand || vm.operationState != .normal)

            Button {
                Task { await vm.fetch() }
            } label: {
                Label("Fetch", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(vm.isBusy || vm.isRunningCommand || vm.operationState != .normal)

            if vm.isBusy { ProgressView().controlSize(.small) }
        }
    }

    private var auxiliaryButtons: some View {
        HStack(spacing: 12) {
            Button {
                Task { await vm.stashPush(message: nil, includeUntracked: true) }
            } label: {
                Label("Stash", systemImage: "tray.and.arrow.down")
            }
            .disabled(vm.isBusy || vm.isRunningCommand || vm.operationState != .normal || (vm.status?.dirtyCount ?? 0) == 0)

            Button {
                vm.toggleCommandPane()
            } label: {
                Label("Command Runner", systemImage: vm.isCommandPaneVisible ? "terminal.fill" : "terminal")
            }
            .tint(vm.isCommandPaneVisible ? theme.accent : nil)
            .help("Command Runner")

        }
    }

    private var status: some View {
        VStack(alignment: .trailing, spacing: 2) {
            if let prInfo = vm.prInfo {
                PRBadgeView(info: prInfo)
            }
            if let error = vm.hostingError {
                Button("Review connection needs attention") { vm.selectedSection = .reviews }
                    .font(theme.caption).help(error)
            }
            if let error = vm.lastAutoFetchError {
                Button {
                    vm.actionError = GitError(command: "Automatic fetch", exitCode: -1, stderr: error)
                } label: {
                    Label("Auto-fetch failed — Details", systemImage: "exclamationmark.triangle")
                }.font(theme.caption)
            }
            if let record = vm.undoRecord {
                Button {
                    Task { await vm.undoLastSync() }
                } label: {
                    Label("Undo \(record.description)", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .font(theme.caption)
                .disabled(vm.isBusy)
            }
            if let aheadBehindText {
                Text(aheadBehindText)
                    .font(theme.caption)
            }
            Text(vm.status?.upstream ?? "No upstream")
                .lineLimit(1).truncationMode(.middle)
                .font(theme.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var aheadBehindText: String? {
        var parts: [String] = []
        if let ahead = vm.status?.ahead, ahead > 0 { parts.append("↑\(ahead)") }
        if let behind = vm.status?.behind, behind > 0 { parts.append("↓\(behind)") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}
