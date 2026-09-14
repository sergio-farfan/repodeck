import RepoDeckCore
import RepoDeckKit
import SwiftUI

struct BulkSummaryBanner: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    let summary: BulkOperationSummary
    @State private var showingResults = false

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: summary.needsAttention ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(summary.needsAttention ? .orange : .green)
                .accessibilityHidden(true)
            Text(summary.text).font(theme.caption).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Results…") { showingResults = true }.font(theme.caption)
            Button { model.bulkSummary = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless).accessibilityLabel("Dismiss operation summary")
                .help("Dismiss operation summary")
        }
        .padding(10)
        .background(.regularMaterial)
        .fixedSize(horizontal: false, vertical: true)
        .sheet(isPresented: $showingResults) {
            BulkResultsView(summary: summary)
        }
    }
}

private struct BulkResultsView: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    let summary: BulkOperationSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(summary.operation).font(.title2.bold())
            Text(summary.text)
            if summary.needsAttention {
                Text("Open a repository to inspect its current state. Busy repositories were not started. A cancelled action may already have made changes; inspect its result before trying again.")
                    .font(.callout)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(summary.repositories) { repository in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(repository.name).font(.headline)
                                Spacer()
                                Text(status(repository.result)).font(.callout.bold())
                                Button("Open Repository") { open(repository.id) }
                                    .disabled(!model.repos.contains { $0.id == repository.id })
                            }
                            Text(repository.path.path).font(.caption).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            if let reason = reason(repository.result) {
                                DisclosureGroup("Details and next steps") {
                                    VStack(alignment: .leading, spacing: 8) {
                                        if case .failed = repository.result {
                                            Text(OperationFailure(message: reason).message)
                                        }
                                        Text(reason).font(.system(.callout, design: .monospaced))
                                    }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            Divider()
                        }
                    }
                }.padding(2)
            }
            HStack {
                Button("Troubleshooting Help") { HelpWindow.open(.troubleshooting, using: openWindow) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.font(theme.body).padding(20).frame(width: 620, height: 460)
    }

    private func status(_ result: OperationResult) -> String {
        switch result {
        case .succeeded: "Succeeded"
        case .failed: "Failed"
        case .skipped: "Skipped"
        }
    }

    private func reason(_ result: OperationResult) -> String? {
        switch result {
        case .succeeded: nil
        case .failed(let reason), .skipped(let reason): reason
        }
    }

    private func open(_ id: String) {
        model.filterText = ""
        model.attentionFilter = .all
        model.unhideRepo(id)
        model.selectedRepoID = id
        dismiss()
    }
}
