import SwiftUI

/// VS Code-style commit box: a multi-line message field and a prominent
/// Commit button, mounted at the top of `RepoDetailView`. Cmd-Enter commits
/// while the message field has focus.
struct CommitBoxView: View {
    let vm: RepoViewModel

    var body: some View {
        @Bindable var vm = vm

        VStack(alignment: .leading, spacing: 6) {
            TextField("Message (⌘⏎ to commit)", text: $vm.commitMessage, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.roundedBorder)

            Button {
                Task { await vm.commit() }
            } label: {
                HStack {
                    Spacer()
                    if vm.isBusy {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text("Commit")
                    Spacer()
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(isCommitDisabled)

            if showsNoStagedChangesCaption {
                Text("No staged changes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
    }

    private var trimmedMessage: String {
        vm.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isCommitDisabled: Bool {
        trimmedMessage.isEmpty || !vm.hasStagedChanges || vm.isBusy
    }

    /// Shown only when the user has typed a message but nothing is staged —
    /// the reason the otherwise-ready-looking Commit button is disabled.
    private var showsNoStagedChangesCaption: Bool {
        !trimmedMessage.isEmpty && !vm.hasStagedChanges
    }
}
