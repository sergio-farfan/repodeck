import RepoDeckKit
import SwiftUI

/// Grouped list of a repo's pending changes: merge conflicts, staged,
/// unstaged, and untracked, each section shown only when non-empty. Per-file
/// actions and "Stage All" delegate to `RepoViewModel`.
struct ChangesListView: View {
    @Environment(\.theme) private var theme
    let vm: RepoViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if vm.status?.didHitLimit == true {
                truncationNotice
            }

            if let status = vm.status {
                if status.changes.isEmpty {
                    ContentUnavailableView("No Changes", systemImage: "checkmark.circle")
                } else {
                    changesList
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var changesList: some View {
        List {
            if !unmerged.isEmpty {
                Section("Merge Changes (\(unmerged.count))") {
                    ForEach(unmerged) { change in
                        FileChangeRow(change: change, vm: vm, action: nil)
                    }
                }
            }
            if !staged.isEmpty {
                Section("Staged Changes (\(staged.count))") {
                    ForEach(staged) { change in
                        FileChangeRow(change: change, vm: vm, action: .unstage)
                    }
                }
            }
            if !unstaged.isEmpty {
                Section {
                    ForEach(unstaged) { change in
                        FileChangeRow(change: change, vm: vm, action: .stage)
                    }
                } header: {
                    HStack {
                        Text("Changes (\(unstaged.count))")
                        Spacer()
                        Button("Stage All") {
                            Task { await vm.stageAll() }
                        }
                        .buttonStyle(.borderless)
                        .disabled(vm.isBusy)
                    }
                }
            }
            if !untracked.isEmpty {
                Section("Untracked (\(untracked.count))") {
                    ForEach(untracked) { change in
                        FileChangeRow(change: change, vm: vm, action: .stage)
                    }
                }
            }
        }
    }

    private var unmerged: [FileChange] { changes(in: .unmerged) }
    private var staged: [FileChange] { changes(in: .staged) }
    private var unstaged: [FileChange] { changes(in: .unstaged) }
    private var untracked: [FileChange] { changes(in: .untracked) }

    private func changes(in area: ChangeArea) -> [FileChange] {
        vm.status?.changes.filter { $0.area == area } ?? []
    }

    private var truncationNotice: some View {
        Label("Too many changes — showing a partial list.", systemImage: "exclamationmark.triangle.fill")
            .font(theme.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.yellow.opacity(0.3), in: Capsule())
            .padding(.horizontal, 8)
            .padding(.top, 6)
    }
}
