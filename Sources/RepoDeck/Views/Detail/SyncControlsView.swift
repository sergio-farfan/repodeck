import SwiftUI

/// Horizontal pull/push/fetch bar mounted under the commit box, plus an
/// ahead/behind readout for the current upstream.
struct SyncControlsView: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var model
    let vm: RepoViewModel

    var body: some View {
        HStack(spacing: 12) {
            Button {
                Task { await vm.pull() }
            } label: {
                Label("Pull", systemImage: "arrow.down")
            }
            .disabled(vm.isBusy)

            Button {
                Task { await vm.push(using: model.isGhAvailable ? model.gh : nil) }
            } label: {
                Label("Push", systemImage: "arrow.up")
            }
            .disabled(vm.isBusy)

            Button {
                Task { await vm.fetch() }
            } label: {
                Label("Fetch", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(vm.isBusy)

            Button {
                Task { await vm.stashPush(message: nil, includeUntracked: true) }
            } label: {
                Label("Stash", systemImage: "tray.and.arrow.down")
            }
            .disabled(vm.isBusy || (vm.status?.dirtyCount ?? 0) == 0)

            Button {
                vm.toggleCommandPane()
            } label: {
                Label("Command Runner", systemImage: vm.isCommandPaneVisible ? "terminal.fill" : "terminal")
            }
            .tint(vm.isCommandPaneVisible ? theme.accent : nil)
            .help("Command Runner")

            if vm.isBusy {
                ProgressView()
                    .controlSize(.small)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                if let prInfo = vm.prInfo {
                    PRBadgeView(info: prInfo)
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
                    .font(theme.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
    }

    private var aheadBehindText: String? {
        var parts: [String] = []
        if let ahead = vm.status?.ahead, ahead > 0 { parts.append("↑\(ahead)") }
        if let behind = vm.status?.behind, behind > 0 { parts.append("↓\(behind)") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}
