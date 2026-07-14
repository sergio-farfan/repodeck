import RepoDeckKit
import SwiftUI

/// Per-repo settings editor, opened from the repo row's context menu
/// ("Repository Settings…"). All writes go straight through
/// `AppModel.updateSettings(for:_:)` — there is no Apply/Cancel staging.
struct RepoSettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    let vm: RepoViewModel

    @State private var newGroupName = ""

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 2) {
                    Text(vm.repo.name)
                        .font(theme.title)
                    Text(vm.repo.path.path)
                        .font(theme.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Section("Sync") {
                Toggle("Auto-Rebase on Rejected Push", isOn: Binding(
                    get: { model.settings(for: vm.id).autoRebaseOnRejectedPush },
                    set: { newValue in
                        model.updateSettings(for: vm.id) { $0.autoRebaseOnRejectedPush = newValue }
                    }
                ))

                Picker("Auto-Fetch", selection: Binding(
                    get: { model.settings(for: vm.id).autoFetchInterval },
                    set: { newValue in
                        model.updateSettings(for: vm.id) { $0.autoFetchInterval = newValue }
                    }
                )) {
                    ForEach(AutoFetchInterval.allCases, id: \.self) { interval in
                        Text(interval.label).tag(interval)
                    }
                }
            }

            Section("Group") {
                Picker("Group", selection: Binding(
                    get: { model.settings(for: vm.id).group },
                    set: { newValue in
                        model.updateSettings(for: vm.id) { $0.group = newValue }
                    }
                )) {
                    Text("None").tag(String?.none)
                    ForEach(model.groupNames, id: \.self) { name in
                        Text(name).tag(Optional(name))
                    }
                }

                HStack {
                    TextField("New group", text: $newGroupName)
                    Button("Add") {
                        addGroup()
                    }
                }
            }

            Section {
                HStack {
                    Spacer()
                    Button("Done") {
                        model.repoSettingsTarget = nil
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .padding(.vertical, 8)
    }

    /// Trims `newGroupName`, ignores empty/duplicate (case-insensitive)
    /// input, assigns the trimmed name to this repo, and clears the field.
    private func addGroup() {
        let trimmed = newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !model.groupNames.contains(where: { $0.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }) else {
            return
        }
        model.updateSettings(for: vm.id) { $0.group = trimmed }
        newGroupName = ""
    }
}
