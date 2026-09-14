import AppKit
import RepoDeckCore
import SwiftUI

/// Bounded inline summary with full output in a scrollable details sheet.
struct OperationMessageView: View {
    @Environment(\.theme) private var theme
    let failure: OperationFailure
    let onAction: (FailureRecoveryAction) -> Void
    var dismiss: (() -> Void)?
    @State private var details: OperationFailure?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(failure.title).font(theme.callout.bold()).lineLimit(2)
                    Text(failure.operation).font(theme.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Text(failure.message).font(theme.caption).lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let dismiss {
                    Button(action: dismiss) { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).accessibilityLabel("Dismiss message")
                        .help("Dismiss message")
                }
            }
            HStack {
                Button("Details & Help…") { details = failure }
                if let action = failure.actions.first, action != .help {
                    Button(action.label) { onAction(action) }
                }
            }.font(theme.caption)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.3)))
        .padding(.horizontal, 10).padding(.vertical, 6)
        .sheet(isPresented: Binding(get: { details != nil }, set: { if !$0 { details = nil } })) {
            if let details {
                OperationDetailsView(failure: details, onAction: { action in
                    self.details = nil
                    onAction(action)
                })
            }
        }
    }
}

private struct OperationDetailsView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let failure: OperationFailure
    let onAction: (FailureRecoveryAction) -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(failure.title).font(theme.ui(20, weight: .bold))
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(failure.message).textSelection(.enabled)
                    Text("Next steps").font(.headline)
                    ForEach(failure.actions, id: \.self) { action in
                        Button(action.label) { onAction(action) }
                    }
                    Text("Technical details").font(.headline)
                    Text(failure.details)
                        .font(theme.mono(12))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(2)
            }
            Divider()
            HStack {
                Button(copied ? "Copied" : "Copy Details") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(failure.details, forType: .string)
                    copied = true
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.font(theme.body).padding(20).frame(width: 580, height: 460)
    }
}

/// Navigation and read paths only: no write retries or conflict draft replacement.
struct RepositoryFailureBanner: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    let vm: RepoViewModel
    let failure: OperationFailure
    var dismiss: (() -> Void)?

    var body: some View {
        OperationMessageView(failure: failure, onAction: recover, dismiss: dismiss)
    }

    private func recover(_ action: FailureRecoveryAction) {
        switch action {
        case .showChanges: vm.selectedSection = .changes
        case .showConflicts: vm.selectedSection = .conflicts
        case .showBranches: vm.selectedSection = .branches
        case .configureIdentity: model.gitIdentityTarget = vm
        case .openSettings: openSettings()
        case .openTerminal: model.openInTerminal(vm.repo.path, repoID: vm.id)
        case .refresh: Task { await vm.refreshForExternalChange() }
        case .help: HelpWindow.open(.troubleshooting, using: openWindow)
        }
    }
}
