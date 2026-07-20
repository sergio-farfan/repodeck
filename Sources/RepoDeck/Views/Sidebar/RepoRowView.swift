import AppKit
import RepoDeckKit
import SwiftUI

struct RepoRowView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    let vm: RepoViewModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .foregroundStyle(isWarning ? Color.yellow : Color.primary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(vm.repo.name)
                    .font(theme.body)

                if let branch = vm.status?.branch {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.branch")
                        Text(branch)
                        if showsMainBranchWarning {
                            Circle()
                                .fill(Color.orange)
                                .frame(width: 6, height: 6)
                                .help("Uncommitted changes on \(branch)")
                        }
                    }
                    .font(theme.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 4)

            if let aheadBehindText {
                Text(aheadBehindText)
                    .font(theme.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .badge(vm.status?.dirtyCount ?? 0)
        .tag(vm.id)
        .contextMenu {
            contextMenuContent
        }
    }

    private var isWarning: Bool {
        vm.statusError != nil || vm.isMissing
    }

    private var iconName: String {
        isWarning ? "exclamationmark.triangle.fill" : "folder"
    }

    private var showsMainBranchWarning: Bool {
        guard let branch = vm.status?.branch, (vm.status?.dirtyCount ?? 0) > 0 else { return false }
        return branch == "main" || branch == "master"
    }

    private var aheadBehindText: String? {
        guard let status = vm.status else { return nil }
        var parts: [String] = []
        if let ahead = status.ahead, ahead > 0 { parts.append("↑\(ahead)") }
        if let behind = status.behind, behind > 0 { parts.append("↓\(behind)") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// VS Code's install location if present; the menu item is omitted otherwise.
    private var vsCodeURL: URL? {
        let url = URL(fileURLWithPath: "/Applications/Visual Studio Code.app")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    @ViewBuilder
    private var moveToGroupContent: some View {
        let currentGroup = model.settings(for: vm.id).group
        let otherGroups = model.groupNames.filter { $0 != currentGroup }

        ForEach(otherGroups, id: \.self) { name in
            Button(name) {
                model.assignGroup(name, to: vm.id)
            }
        }

        if currentGroup != nil {
            Divider()
            Button("None") {
                model.assignGroup(nil, to: vm.id)
            }
        }

        Divider()

        Button("New Group…") {
            model.repoSettingsTarget = vm
        }
    }

    @ViewBuilder
    private var contextMenuContent: some View {
        Button {
            model.togglePin(vm.id)
        } label: {
            if model.settings(for: vm.id).isPinned {
                Label("Unpin", systemImage: "star.slash")
            } else {
                Label("Pin", systemImage: "star")
            }
        }

        Toggle("Auto-Rebase on Rejected Push", isOn: Binding(
            get: { model.settings(for: vm.id).autoRebaseOnRejectedPush },
            set: { _ in model.toggleAutoRebase(vm.id) }
        ))

        Button("Repository Settings…") {
            model.repoSettingsTarget = vm
        }

        Menu("Move to Group") {
            moveToGroupContent
        }

        Divider()

        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([vm.repo.path])
        }

        Button("Open in Terminal") {
            NSWorkspace.shared.open(
                [vm.repo.path],
                withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                configuration: NSWorkspace.OpenConfiguration(),
                completionHandler: nil
            )
        }

        Button("Open Command Runner") {
            model.selectedRepoID = vm.id
            vm.isCommandPaneVisible = true
        }

        if let vsCodeURL {
            Button("Open in VS Code") {
                NSWorkspace.shared.open(
                    [vm.repo.path],
                    withApplicationAt: vsCodeURL,
                    configuration: NSWorkspace.OpenConfiguration(),
                    completionHandler: nil
                )
            }
        }

        Button("Copy Path") {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(vm.repo.path.path, forType: .string)
        }

        Divider()

        Button("Remove from List") {
            model.hideRepo(vm.id)
        }
    }
}
