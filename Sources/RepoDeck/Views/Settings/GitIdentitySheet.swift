import RepoDeckCore
import RepoDeckKit
import SwiftUI

/// The destination is captured when opened; changing sidebar selection cannot
/// redirect a save. Opening or editing the form does not change Git settings.
struct GitIdentitySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var editor: GitIdentityEditor

    init(vm: RepoViewModel) {
        _editor = State(initialValue: GitIdentityEditor(repo: vm))
    }

    var body: some View {
        @Bindable var editor = editor
        VStack(alignment: .leading, spacing: 16) {
            Text("Configure Commit Author").font(theme.ui(22, weight: .bold))
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(editor.repo.repo.name).font(theme.body.bold())
                        Text(editor.repo.repo.path.path)
                            .font(theme.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Text("Set the default name and email for new commits. SSH keys and your GitHub or GitLab account handle access separately.")

                    Picker("Save for", selection: Binding(
                        get: { editor.scope },
                        set: { scope in Task { await editor.selectScope(scope) } }
                    )) {
                        Text("This repository").tag(GitIdentityScope.repository)
                        Text("My Git default").tag(GitIdentityScope.globalDefault)
                    }
                    .disabled(editor.isLoading || editor.isSaving)

                    Text(editor.scope == .repository
                         ? "Saves this repository’s default name and email, including linked worktrees sharing its configuration. Worktree settings, author-specific settings, or environment overrides can take precedence."
                         : "Saves your default name and email for Git on this Mac, including other Git apps. Repository, worktree, author-specific settings, or environment overrides can take precedence.")
                        .font(theme.caption).foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Author name")
                        TextField("Your name", text: $editor.name)
                            .accessibilityLabel("Default commit author name")
                        Text("Author email")
                        TextField("you@example.com", text: $editor.email)
                            .accessibilityLabel("Default commit author email")
                        Text("Use the email you want recorded in new commits, including a private commit email if you prefer.")
                            .font(theme.caption).foregroundStyle(.secondary)
                    }
                    .textFieldStyle(.roundedBorder)
                    .disabled(editor.isLoading || editor.isSaving)

                    if editor.isLoading { ProgressView("Reading Git settings…") }
                    if let error = editor.error {
                        Label("Couldn’t save or read author settings", systemImage: "exclamationmark.triangle")
                            .font(theme.body.bold())
                        Text(error).textSelection(.enabled)
                        if !editor.hasLoaded {
                            Button("Retry Reading Settings") { Task { await editor.load() } }
                                .disabled(editor.isLoading || editor.isSaving)
                        }
                    }
                    if let notice = editor.notice {
                        Label(notice, systemImage: "info.circle").textSelection(.enabled)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Author for new commits").font(theme.body.bold())
                        if let error = editor.effectiveIdentityError {
                            Label("Commit author unavailable", systemImage: "exclamationmark.triangle")
                            Text(error).textSelection(.enabled)
                            Text("You can still save the defaults above. Author-specific or environment overrides remain in place; see Help if the author stays unavailable.")
                                .font(theme.caption).foregroundStyle(.secondary)
                            Button("Reload Author") { Task { await editor.load() } }
                                .disabled(editor.isLoading || editor.isSaving)
                        } else if let identity = editor.effectiveIdentity {
                            Text(identity.name ?? "No author name configured")
                            Text(identity.email ?? "No author email configured")
                                .foregroundStyle(.secondary)
                        }
                        Text("This is the current author for ordinary new commits. Cherry-pick and rebase normally preserve the original commit’s author.")
                            .font(theme.caption).foregroundStyle(.secondary)
                    }.textSelection(.enabled)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(2)
            }
            Divider()
            HStack {
                Button("Help") { HelpWindow.open(.gitTroubleshooting, using: openWindow) }
                Spacer()
                Button(editor.notice == nil ? "Cancel" : "Done") { dismiss() }
                    .keyboardShortcut(.cancelAction).disabled(editor.isSaving)
                Button(editor.isSaving ? "Saving…" : "Save Commit Author") {
                    Task {
                        if await editor.save() {
                            await withTaskGroup(of: Void.self) { group in
                                for vm in model.repos {
                                    group.addTask { await vm.refreshIdentity() }
                                }
                            }
                        }
                    }
                }
                .keyboardShortcut(.defaultAction).disabled(!editor.canSave)
            }
        }
        .font(theme.body).padding(20).frame(width: 580, height: 600)
        .interactiveDismissDisabled(editor.isSaving)
        .task { await editor.load() }
    }
}
