import RepoDeckCore
import RepoDeckKit
import SwiftUI

/// Bottom-of-sidebar author strip: the selected repo's resolved commit
/// author (avatar-with-initials + name/email) plus the active `gh`
/// account, when either exists. Renders nothing at all when there's no
/// selection and no gh login, so the sidebar keeps its clean edge.
struct SidebarIdentityFooter: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let vm = model.selectedRepo
        if vm != nil || model.ghAccountLogin != nil {
            VStack(alignment: .leading, spacing: 0) {
                Divider()
                content(for: vm)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
            // Opaque: list rows scroll beneath this inset and would show
            // through a transparent footer.
            .background(Theme.sidebarBackground(for: colorScheme))
            .task(id: model.selectedRepoID) {
                await model.selectedRepo?.refreshIdentity()
            }
        }
    }

    private func content(for vm: RepoViewModel?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let vm {
                gitIdentityRow(vm)
                HStack {
                    Button(vm.identityLoadError == nil && vm.gitIdentity?.isComplete == true ? "Edit Author…" : "Configure Author…") {
                        model.gitIdentityTarget = vm
                    }
                    .lineLimit(1)
                    .disabled(vm.isBusy || vm.isRunningCommand)
                    .accessibilityLabel(vm.identityLoadError == nil && vm.gitIdentity?.isComplete == true ? "Edit Commit Author" : "Configure Commit Author")
                    .accessibilityHint("Set the author name and email for new commits")
                    if vm.identityLoadError != nil {
                        Button("Retry") { Task { await vm.refreshIdentity() } }
                            .disabled(vm.isLoadingIdentity)
                            .accessibilityLabel("Retry reading commit author")
                    }
                }.font(theme.caption).buttonStyle(.link)
            }
            if model.isGhAvailable, let login = model.ghAccountLogin {
                HStack(spacing: 6) {
                    Image(systemName: "person.crop.circle")
                    Text("GitHub account · @\(login)").lineLimit(1)
                }
                .font(theme.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func gitIdentityRow(_ vm: RepoViewModel) -> some View {
        let identity = vm.identityLoadError == nil ? vm.gitIdentity : nil
        return HStack(spacing: 8) {
            avatar(initials: identity?.initials)

            VStack(alignment: .leading, spacing: 1) {
                Text("Commit author").font(theme.caption).foregroundStyle(.secondary)
                if let primary = identity?.name ?? identity?.email {
                    Text(primary)
                        .font(theme.body)
                        .lineLimit(1)
                } else {
                    Text(vm.identityLoadError != nil ? "Unavailable" :
                            !vm.hasLoadedIdentity ? "Checking…" : "Not configured")
                        .font(theme.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                // Email as the caption line only when it isn't already the
                // primary line (i.e. a name exists too).
                if identity?.name != nil, let email = identity?.email {
                    Text(email)
                        .font(theme.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if vm.identityLoadError != nil {
                    Text("Set a name and email, or retry.")
                        .font(theme.caption).foregroundStyle(.secondary).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                } else if vm.hasLoadedIdentity, identity?.isConfigured == true, identity?.isComplete != true {
                    Text(identity?.name == nil ? "Author name is missing" : "Author email is missing")
                        .font(theme.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }

            Spacer(minLength: 0)
        }
    }

    private func avatar(initials: String?) -> some View {
        Circle()
            .fill(Color.secondary.opacity(0.25))
            .frame(width: 28, height: 28)
            .overlay {
                if let initials {
                    Text(initials)
                        .font(theme.caption)
                        .fontWeight(.semibold)
                } else {
                    Image(systemName: "person.fill")
                        .foregroundStyle(.secondary)
                }
            }
    }
}
