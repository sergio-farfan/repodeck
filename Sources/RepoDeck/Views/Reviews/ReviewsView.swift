import AppKit
import RepoDeckCore
import RepoDeckKit
import SwiftUI

/// Hosting UI with no dependency on the application's repository view model.
/// Drafts are saved per worktree/destination; remote writes require a concrete preview.
struct ReviewsView: View {
    let repoURL: URL
    let gitPath: String
    let ghPath: String?
    let glabPath: String?
    let refreshRevision: Int
    let onCheckout: ((URL) -> Void)?
    @State private var store: ReviewsStore
    @State private var preview: ReviewPreview?
    @State private var detailTab = "Overview"
    private var configuration: ReviewToolConfiguration {
        ReviewToolConfiguration(repositoryPath: repoURL.path, gitPath: gitPath, ghPath: ghPath, glabPath: glabPath)
    }

    init(repoURL: URL, gitPath: String = GitDefaults.gitPath, ghPath: String? = nil, glabPath: String? = nil,
         refreshRevision: Int = 0,
         onCheckout: ((URL) -> Void)? = nil) {
        self.repoURL = repoURL; self.gitPath = gitPath; self.ghPath = ghPath; self.glabPath = glabPath
        self.refreshRevision = refreshRevision
        self.onCheckout = onCheckout
        _store = State(initialValue: ReviewsStore.session(repoURL: repoURL, gitPath: gitPath, ghPath: ghPath, glabPath: glabPath))
    }
    var body: some View {
        VStack(spacing: 0) {
            connectionBar
            if let error = store.error {
                HStack(alignment: .top) {
                    Text(error).textSelection(.enabled).foregroundStyle(.red)
                    Spacer()
                    Button("Dismiss") { store.error = nil }
                }.font(.caption).padding(8)
            }
            Divider()
            if store.client != nil {
                HSplitView {
                    requestList.frame(minWidth: 170, idealWidth: 230, maxWidth: 280)
                    detailPane.frame(minWidth: 280)
                }
            } else {
                ContentUnavailableView("Connect a Hosting Service", systemImage: "network",
                    description: Text(store.diagnostic?.message ?? "Select a remote and its hosting provider. Sign in using gh or glab, then reconnect."))
            }
        }
        .task(id: configuration) {
            if store.repoURL != repoURL { store = ReviewsStore.session(repoURL: repoURL, gitPath: gitPath, ghPath: ghPath, glabPath: glabPath) }
            await store.discover(reconnect: true)
        }
        .task(id: refreshRevision) { await store.refresh() }
        .task(id: store.client?.repository.id) {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                guard !store.isBusy else { continue }
                await store.refresh()
            }
        }
        .sheet(item: $preview) { value in
            VStack(alignment: .leading, spacing: 14) {
                Text(value.title).font(.title2)
                Text("Account: \(store.diagnostic?.account ?? "Unknown") on \(store.client?.repository.host ?? "")")
                Text(value.destination).font(.callout).textSelection(.enabled)
                ScrollView { Text(value.body).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                    .frame(maxHeight: 260)
                HStack {
                    Button("Cancel") { preview = nil }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(value.confirmLabel) {
                        preview = nil
                        Task { if let checkout = await store.perform(value) { onCheckout?(checkout) } }
                    }.buttonStyle(.borderedProminent).disabled(store.isBusy || store.client == nil)
                }
            }.padding(20).frame(width: 560)
        }
    }
    private var connectionBar: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Picker("Remote", selection: Binding(get: { store.remoteName }, set: {
                    store.remoteName = $0; store.selectionChanged()
                })) {
                    ForEach(store.remotes, id: \.name) { remote in Text(remote.name).tag(remote.name) }
                }.frame(maxWidth: 190).disabled(store.isBusy)
                Picker("Provider", selection: Binding(get: { store.provider }, set: {
                    store.provider = $0; store.selectionChanged(inferProvider: false)
                })) {
                    ForEach(HostingProviderKind.allCases) { Text($0.label).tag($0) }
                }.frame(maxWidth: 190).disabled(store.isBusy)
                Button("Connect / Refresh") { Task { await store.connect() } }.disabled(store.isBusy)
                if store.isBusy { ProgressView().controlSize(.small) }
            }
            if let diagnostic = store.diagnostic { Text(diagnostic.message).font(.caption).foregroundStyle(.secondary) }
            if let destination = store.client?.repository { Text(destination.displayName).font(.caption).textSelection(.enabled) }
        }.padding(10)
    }
    private var requestList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(store.provider == .github ? "Pull Requests" : "Merge Requests").font(.headline)
                Spacer()
                Button("New") { store.isCreating = true; store.selected = nil }
            }.padding(8)
            List(store.requests, selection: $store.selected) { request in
                VStack(alignment: .leading, spacing: 3) {
                    Text("#\(request.number) \(request.title)").lineLimit(2)
                    Text("\(request.sourceRepository):\(request.sourceBranch)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if request.isDraft { Text("Draft").font(.caption2) }
                }.tag(request.number)
            }
            if store.hasMore { Button("Load More") { Task { await store.loadMore() } }.padding(8).disabled(store.isBusy) }
        }
        .onChange(of: store.selected) {
            guard store.selected != nil else { return }
            store.isCreating = false
            Task { await store.loadDetail() }
        }
    }
    @ViewBuilder private var detailPane: some View {
        if store.isCreating { createForm }
        else if let detail = store.detail, detail.request.number == store.selected {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("#\(detail.request.number) \(detail.request.title)").font(.headline)
                    Spacer()
                    Link("Open in Browser", destination: detail.request.url)
                }
                Text("\(detail.request.sourceRepository):\(detail.request.sourceBranch) → \(detail.request.targetBranch)")
                    .font(.caption).textSelection(.enabled)
                HStack {
                    Button("Open in New Worktree…") { chooseWorktree(detail.request) }.disabled(store.isBusy)
                    if detail.request.isDraft {
                        Button("Mark Ready…") { preview = store.readyPreview(detail.request) }.disabled(store.isBusy)
                    }
                    Picker("Merge method", selection: $store.mergeMethod) {
                        ForEach(detail.capabilities.mergeMethods) { Text($0.label).tag($0) }
                    }.labelsHidden().frame(maxWidth: 115)
                    Button("Merge…") { preview = store.mergePreview(detail.request) }
                        .disabled(store.isBusy || detail.request.isDraft || !detail.request.isOpen)
                }
                ForEach(detail.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                Picker("Review section", selection: $detailTab) {
                    ForEach(["Overview", "Files", "Checks", "Discussion"], id: \.self) { Text($0) }
                }.pickerStyle(.segmented)
                reviewContent(detail)
                Divider()
                reviewComposer(detail)
            }.padding(10)
        } else { ContentUnavailableView("Select a Review", systemImage: "text.bubble") }
    }
    @ViewBuilder private func reviewContent(_ detail: ReviewDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                switch detailTab {
                case "Files":
                    if detail.files.isEmpty { Text("No files available.").foregroundStyle(.secondary) }
                    ForEach(detail.files) { file in
                        DisclosureGroup("\(file.status): \(file.path)") {
                            Text(file.patch ?? "The hosting service did not supply this patch (binary, large, or unavailable). Open the review in your browser to inspect it.")
                                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                case "Checks":
                    if detail.checks.isEmpty { Text("No checks reported.").foregroundStyle(.secondary) }
                    ForEach(detail.checks) { check in
                        HStack { Text(check.name); Spacer(); Text(check.status); if let url = check.url { Link("Details", destination: url) } }
                    }
                case "Discussion":
                    if detail.comments.isEmpty { Text("No discussion yet.").foregroundStyle(.secondary) }
                    ForEach(detail.comments) { comment in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(comment.author)\(comment.state.map { " · \($0)" } ?? "")").font(.headline)
                            Text(ReviewsStore.visibleBody(comment.body)).textSelection(.enabled)
                        }
                    }
                default:
                    Text(ReviewsStore.visibleBody(detail.request.body)).textSelection(.enabled)
                    Text("Head: \(detail.request.headOID)").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func reviewComposer(_ detail: ReviewDetail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Review message", text: $store.reviewBody, axis: .vertical).lineLimit(2...5).textFieldStyle(.roundedBorder)
                .onChange(of: store.reviewBody) { store.saveDraft() }
            HStack {
                Picker("Review action", selection: $store.reviewAction) {
                    ForEach(ReviewAction.allCases.filter { $0 != .requestChanges || detail.capabilities.requestChanges }) { Text($0.label).tag($0) }
                }.frame(maxWidth: 210)
                Button("Preview Submission…") { preview = store.submitPreview(detail.request) }
                    .disabled(store.isBusy || !detail.request.isOpen || (store.reviewAction != .approve && store.reviewBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
            if store.provider == .gitlab {
                Text("GitLab formal change requests are unavailable in this adapter. Use Comment for requested changes; approval submits only the approval action.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var createForm: some View {
        Form {
            Text("New \(store.provider.requestLabel)").font(.headline)
            Picker("Source remote", selection: $store.sourceRemoteName) {
                ForEach(store.remotes, id: \.name) { Text($0.name).tag($0.name) }
            }
            TextField("Source branch (already pushed)", text: $store.sourceBranch)
            TextField("Destination branch", text: $store.targetBranch)
            TextField("Title", text: $store.draftTitle)
            TextField("Description", text: $store.draftBody, axis: .vertical).lineLimit(4...10)
            Toggle("Create as draft", isOn: $store.createAsDraft)
            Button("Preview Creation…") { preview = store.createPreview() }
                .disabled(store.isBusy || store.draftTitle.isEmpty || store.sourceBranch.isEmpty || store.targetBranch.isEmpty)
            Text("The source branch must already exist on the selected source remote. Your current checkout is unchanged.")
                .font(.caption).foregroundStyle(.secondary)
        }.formStyle(.grouped)
        .onChange(of: store.draftTitle) { store.saveDraft() }
        .onChange(of: store.draftBody) { store.saveDraft() }
        .onChange(of: store.sourceBranch) { store.saveDraft() }
        .onChange(of: store.targetBranch) { store.saveDraft() }
        .onChange(of: store.createAsDraft) { store.saveDraft() }
        .onChange(of: store.sourceRemoteName) { store.saveDraft() }
    }
    private func chooseWorktree(_ request: ReviewRequest) {
        let panel = NSSavePanel()
        panel.title = "Choose a New Review Worktree Directory"
        panel.nameFieldStringValue = "\(repoURL.lastPathComponent)-review-\(request.number)"
        panel.directoryURL = repoURL.deletingLastPathComponent()
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        preview = store.checkoutPreview(request, destination: destination)
    }
}

private struct ReviewToolConfiguration: Hashable {
    let repositoryPath: String
    let gitPath: String
    let ghPath: String?
    let glabPath: String?
}
