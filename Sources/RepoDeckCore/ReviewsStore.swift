import Foundation
import Observation
import RepoDeckKit

public struct ReviewPreview: Identifiable {
    public let id = UUID()
    public let title: String
    public let destination: String
    public let body: String
    public let confirmLabel: String
    public let repositoryID: String
    public let account: String?
    public let action: Action
    public enum Action {
        case create(ReviewDraft, UUID)
        case submit(Int, String, ReviewAction, String, UUID)
        case ready(Int, String)
        case merge(Int, String, ReviewMergeMethod)
        case checkout(Int, String, URL)
    }
}

@MainActor @Observable
public final class ReviewsStore {
    private static var sessions: [String: ReviewsStore] = [:]
    public static func session(repoURL: URL, gitPath: String, ghPath: String?, glabPath: String?) -> ReviewsStore {
        let key = repoURL.resolvingSymlinksInPath().standardizedFileURL.path
        if let stored = sessions[key] {
            stored.updateTools(gitPath: gitPath, ghPath: ghPath, glabPath: glabPath)
            return stored
        }
        let result = ReviewsStore(repoURL: repoURL, gitPath: gitPath, ghPath: ghPath, glabPath: glabPath)
        sessions[key] = result
        return result
    }
    public let repoURL: URL
    public var gitPath: String
    public var ghPath: String?
    public var glabPath: String?
    public var remotes: [(name: String, url: String)] = []
    public var remoteName = "origin"
    public var provider = HostingProviderKind.github
    public var sourceRemoteName = "origin"
    public var client: HostingClient?
    public var diagnostic: HostingDiagnostic?
    public var requests: [ReviewRequest] = []
    public var selected: Int?
    public var detail: ReviewDetail?
    public var error: String?
    public var isBusy = false
    private var isMutating = false
    public var isCreating = false
    public var page = 1
    public var hasMore = false
    private var reviewDraft = ReviewTextDraft()
    public var reviewBody: String {
        get { reviewDraft.body }
        set { reviewDraft.body = newValue }
    }
    public var reviewAction = ReviewAction.comment
    public var mergeMethod = ReviewMergeMethod.merge
    public var draftTitle = ""
    public var draftBody = ""
    public var sourceBranch = ""
    public var targetBranch = ""
    public var createAsDraft = true
    private var createOperationID = UUID()
    private var reviewOperationID: UUID {
        get { reviewDraft.operationID }
        set { reviewDraft.operationID = newValue }
    }
    private var generation = 0
    private var refreshGeneration = 0
    private var detailGeneration = 0
    private var remoteGeneration = 0
    private var draftDestinationID: String?
    private let preferences: UserDefaults
    private let runner: HostingCommandRunner
    private var draftKey: String? {
        draftDestinationID.map { "reviews.draft.v2:\(repoURL.resolvingSymlinksInPath().standardizedFileURL.path):\($0)" }
    }
    public init(repoURL: URL, gitPath: String, ghPath: String?, glabPath: String?,
                preferences: UserDefaults = .standard,
                runner: @escaping HostingCommandRunner = HostingClient.liveRunner) {
        self.repoURL = repoURL; self.gitPath = gitPath; self.ghPath = ghPath; self.glabPath = glabPath
        self.preferences = preferences; self.runner = runner
    }
    public func updateTools(gitPath: String, ghPath: String?, glabPath: String?) {
        guard self.gitPath != gitPath || self.ghPath != ghPath || self.glabPath != glabPath else { return }
        self.gitPath = gitPath; self.ghPath = ghPath; self.glabPath = glabPath
        // Invalidate the old executable before the reconnect task starts. A preview
        // must not send through a cached CLI after the user applies new settings.
        generation += 1; refreshGeneration += 1; detailGeneration += 1; remoteGeneration += 1
        client = nil; diagnostic = nil
        isBusy = isMutating
    }
    public func discover(reconnect: Bool = false) async {
        while isMutating {
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
        }
        guard !Task.isCancelled else { return }
        await connect()
    }

    private var selectedRepository: HostingRepository? {
        guard let remote = remotes.first(where: { $0.name == remoteName }) else { return nil }
        return HostingRepository.parse(remote: remote.url, name: remote.name, provider: provider)
    }

    public func selectionChanged(inferProvider: Bool = true) {
        guard !isMutating else { return }
        saveDraft()
        generation += 1; refreshGeneration += 1; detailGeneration += 1
        client = nil; diagnostic = nil
        if inferProvider, let remote = remotes.first(where: { $0.name == remoteName }),
           let parsed = HostingRepository.parse(remote: remote.url, name: remote.name) { provider = parsed.provider }
        let destinationID = selectedRepository?.id
        if destinationID != draftDestinationID {
            detail = nil; selected = nil; requests = []
            draftDestinationID = destinationID
            restoreDraft()
        }
        if provider == .gitlab, reviewAction == .requestChanges { reviewAction = .comment }
        mergeMethod = .merge
    }

    /// Git config can change outside RepoDeck. Re-read it even for an existing session.
    private func reloadRemotes() async throws {
        guard !isMutating else { throw CancellationError() }
        remoteGeneration += 1
        let request = remoteGeneration
        let discovered = try await HostingClient.remotes(in: repoURL, gitPath: gitPath)
        guard request == remoteGeneration, !Task.isCancelled, !isMutating else { throw CancellationError() }
        let previousName = remoteName
        let previousURL = remotes.first(where: { $0.name == previousName })?.url
        remotes = discovered
        if !remotes.contains(where: { $0.name == remoteName }) {
            remoteName = remotes.first(where: { $0.name == "origin" })?.name ?? remotes.first?.name ?? ""
        }
        let nextURL = remotes.first(where: { $0.name == remoteName })?.url
        if remoteName != previousName || nextURL != previousURL || draftDestinationID == nil {
            selectionChanged()
        }
        if !remotes.contains(where: { $0.name == sourceRemoteName }) { sourceRemoteName = remoteName }
    }

    public func connect() async {
        do { try await reloadRemotes() }
        catch is CancellationError { return }
        catch { self.error = error.localizedDescription; return }
        await connectCached()
    }

    private func connectCached() async {
        guard !isMutating else { return }
        guard let remote = remotes.first(where: { $0.name == remoteName }),
              let repo = HostingRepository.parse(remote: remote.url, name: remote.name, provider: provider) else {
            error = "Select a supported HTTPS or SSH remote. Local remotes have no hosting service."; return
        }
        guard let path = (provider == .github ? ghPath : glabPath) ?? HostingClient.discoverTool(provider) else {
            error = "Install \(provider.toolName), then sign in to \(repo.host) and reconnect."; return
        }
        generation += 1
        refreshGeneration += 1
        let current = generation
        isBusy = true
        defer { if current == generation { isBusy = false } }
        let baseRunner = runner
        let candidate = HostingClient(repository: repo, cliPath: path, workingDirectory: repoURL, runner: { [weak self] command in
            if command.arguments.count > 4, command.arguments[4] != "GET" {
                guard let self else { throw CancellationError() }
                try await self.validateWriteDestination(repo, generation: current)
            }
            return try await baseRunner(command)
        })
        let auth = await candidate.diagnostics()
        guard current == generation, !Task.isCancelled else { return }
        diagnostic = auth
        guard auth.isAuthenticated else { client = nil; return }
        client = candidate
        do {
            if sourceBranch.isEmpty {
                let branch = try await ProcessRunner.run(gitPath,
                    arguments: ["-C", repoURL.path, "symbolic-ref", "--quiet", "--short", "HEAD"], timeout: .seconds(10))
                guard current == generation, !Task.isCancelled else { return }
                if sourceBranch.isEmpty, branch.exitCode == 0 {
                    sourceBranch = String(decoding: branch.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            let values = try await candidate.list()
            guard current == generation, !Task.isCancelled else { return }
            requests = values; page = 1; hasMore = values.count == 100; error = nil
            await loadDetail()
        } catch { if current == generation { self.error = error.localizedDescription } }
    }

    private func validateWriteDestination(_ expected: HostingRepository, generation expectedGeneration: Int) async throws {
        guard generation == expectedGeneration else {
            throw HostingError.unsupported("The hosting settings changed. Reconnect and preview the action again.")
        }
        let currentRemotes = try await HostingClient.remotes(in: repoURL, gitPath: gitPath)
        guard generation == expectedGeneration,
              let remote = currentRemotes.first(where: { $0.name == expected.remoteName }),
              HostingRepository.parse(remote: remote.url, name: remote.name, provider: expected.provider)?.id == expected.id else {
            throw HostingError.unsupported("The Git remote changed. Reconnect and preview the destination before submitting.")
        }
    }
    public func refresh() async {
        guard !Task.isCancelled else { return }
        refreshGeneration += 1
        let refreshRequest = refreshGeneration
        // A repository event during connection or submission still needs a refresh.
        // The newest request waits for that action instead of being discarded.
        while isBusy {
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            guard refreshRequest == refreshGeneration, !Task.isCancelled else { return }
        }
        guard refreshRequest == refreshGeneration, !Task.isCancelled else { return }
        do { try await reloadRemotes() }
        catch is CancellationError { return }
        catch { self.error = error.localizedDescription; return }
        guard let client else { await connectCached(); return }
        let current = generation
        let currentRefresh = refreshGeneration
        do {
            let values = try await client.list()
            guard current == generation, currentRefresh == refreshGeneration, !Task.isCancelled else { return }
            requests = values; page = 1; hasMore = values.count == 100
            await loadDetail()
        } catch {
            if current == generation, currentRefresh == refreshGeneration, !Task.isCancelled {
                self.error = error.localizedDescription
            }
        }
    }
    public func loadMore() async {
        guard !isBusy, let client else { return }
        refreshGeneration += 1
        let current = generation
        isBusy = true; defer { if current == generation { isBusy = false } }
        do {
            let values = try await client.list(page: page + 1)
            guard current == generation, !Task.isCancelled else { return }
            let ids = Set(requests.map(\.number)); requests += values.filter { !ids.contains($0.number) }
            page += 1; hasMore = values.count == 100
        } catch { if current == generation, !Task.isCancelled { self.error = error.localizedDescription } }
    }
    public func loadDetail() async {
        guard let selected, let client else { return }
        let current = generation
        detailGeneration += 1
        let requestGeneration = detailGeneration
        do {
            let value = try await client.detail(number: selected)
            guard current == generation, requestGeneration == detailGeneration, self.selected == selected, !Task.isCancelled else { return }
            detail = value
        } catch { if current == generation, requestGeneration == detailGeneration, self.selected == selected, !Task.isCancelled { self.error = error.localizedDescription } }
    }
    public func createPreview() -> ReviewPreview? {
        guard let client, let remote = remotes.first(where: { $0.name == sourceRemoteName }),
              let source = HostingRepository.parse(remote: remote.url, name: remote.name, provider: provider) else {
            error = "Select a source remote."; return nil
        }
        let draft = ReviewDraft(title: draftTitle, body: draftBody, source: source, sourceBranch: sourceBranch, targetBranch: targetBranch, isDraft: createAsDraft)
        saveDraft()
        return ReviewPreview(title: "Create \(provider.requestLabel)", destination: "\(source.displayName):\(sourceBranch) → \(client.repository.displayName):\(targetBranch)",
            body: "\(createAsDraft ? "Draft" : "Ready for review")\n\n\(draftTitle)\n\n\(draftBody)", confirmLabel: "Create", repositoryID: client.repository.id, account: diagnostic?.account, action: .create(draft, createOperationID))
    }
    private func destination(_ request: ReviewRequest) -> String {
        "\(client?.repository.displayName ?? "") #\(request.number)\n\(request.sourceRepository):\(request.sourceBranch) → \(request.targetBranch)\nExpected head: \(request.headOID)"
    }
    public func submitPreview(_ request: ReviewRequest) -> ReviewPreview {
        saveDraft()
        let submittedBody = provider == .gitlab && reviewAction == .approve ? "" : reviewBody
        return ReviewPreview(title: reviewAction.label, destination: destination(request),
            body: submittedBody.isEmpty ? "Submit \(reviewAction.label.lowercased()) for the displayed commit." : submittedBody,
            confirmLabel: "Submit \(reviewAction.label)", repositoryID: client?.repository.id ?? "", account: diagnostic?.account, action: .submit(request.number, request.headOID, reviewAction, submittedBody, reviewOperationID))
    }
    public func readyPreview(_ request: ReviewRequest) -> ReviewPreview {
        ReviewPreview(title: "Mark Ready for Review", destination: destination(request), body: "Make this draft ready for review.", confirmLabel: "Mark Ready", repositoryID: client?.repository.id ?? "", account: diagnostic?.account, action: .ready(request.number, request.headOID))
    }
    public func mergePreview(_ request: ReviewRequest) -> ReviewPreview {
        ReviewPreview(title: "Merge \(provider.requestLabel)", destination: destination(request),
            body: "Method: \(mergeMethod.label). The hosting service will enforce its permissions, required checks, and branch protection. The source branch is kept.",
            confirmLabel: "Merge", repositoryID: client?.repository.id ?? "", account: diagnostic?.account, action: .merge(request.number, request.headOID, mergeMethod))
    }
    public func checkoutPreview(_ request: ReviewRequest, destination url: URL) -> ReviewPreview {
        ReviewPreview(title: "Create Review Worktree", destination: destination(request),
            body: "Create a detached worktree at:\n\(url.path)\n\nYour current branch and working files stay in place.",
            confirmLabel: "Create Worktree", repositoryID: client?.repository.id ?? "", account: diagnostic?.account, action: .checkout(request.number, request.headOID, url))
    }
    public func perform(_ preview: ReviewPreview) async -> URL? {
        guard !isBusy, let client else { return nil }
        let current = generation
        refreshGeneration += 1
        isBusy = true; isMutating = true
        defer { isBusy = false; isMutating = false }
        var checkout: URL?
        do {
            try await client.validateDestinationAndAccount(expectedID: preview.repositoryID, expectedAccount: preview.account)
            guard current == generation else {
                throw HostingError.unsupported("The hosting tool settings changed. Reconnect and preview the action again.")
            }
            try await validateWriteDestination(client.repository, generation: current)
            switch preview.action {
            case .create(let draft, let id):
                try await validateWriteDestination(draft.source, generation: current)
                let created = try await client.create(draft, operationID: id)
                selected = created.number; isCreating = false
                if draftTitle == draft.title && draftBody == draft.body { draftTitle = ""; draftBody = "" }
                createOperationID = UUID()
            case .submit(let number, let head, let action, let body, let id):
                try await client.submit(number: number, expectedHead: head, action: action, body: body, operationID: id)
                reviewDraft.didSubmit(body: body, operationID: id)
            case .ready(let number, let head): try await client.markReady(number: number, expectedHead: head)
            case .merge(let number, let head, let method): try await client.merge(number: number, expectedHead: head, method: method)
            case .checkout(let number, let head, let url):
                try await client.checkout(number: number, expectedHead: head, to: url, gitPath: gitPath); checkout = url
            }
            saveDraft(); error = nil
            guard current == generation else { return checkout }
            let values = try await client.list()
            guard current == generation else { return checkout }
            requests = values; page = 1; hasMore = values.count == 100
            await loadDetail()
        } catch { self.error = error.localizedDescription }
        return checkout
    }
    public func saveDraft() {
        guard let draftKey else { return }
        let values: [String: String] = ["title": draftTitle, "body": draftBody, "source": sourceBranch,
            "target": targetBranch, "sourceRemote": sourceRemoteName, "draft": String(createAsDraft),
            "review": reviewBody, "createID": createOperationID.uuidString, "reviewID": reviewOperationID.uuidString]
        preferences.set(values, forKey: draftKey)
    }
    private func restoreDraft() {
        let values = draftKey.flatMap { preferences.dictionary(forKey: $0) as? [String: String] } ?? [:]
        draftTitle = values["title"] ?? ""; draftBody = values["body"] ?? ""; sourceBranch = values["source"] ?? ""
        targetBranch = values["target"] ?? ""; sourceRemoteName = values["sourceRemote"] ?? remoteName
        createAsDraft = values["draft"] != "false"; reviewBody = values["review"] ?? ""
        createOperationID = values["createID"].flatMap(UUID.init(uuidString:)) ?? UUID()
        reviewOperationID = values["reviewID"].flatMap(UUID.init(uuidString:)) ?? UUID()
    }
    public static func visibleBody(_ body: String) -> String {
        body.replacingOccurrences(of: #"\n?<!-- repodeck-operation:[0-9a-f-]+ -->"#, with: "", options: .regularExpression)
    }
}
