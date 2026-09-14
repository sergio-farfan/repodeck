import Foundation

/// Coordinates safe remote writes; provider-specific wire formats stay in adapters.
/// Every destination is explicit. Authentication remains entirely in gh/glab.
public struct HostingClient: HostingProviding, Sendable {
    public let repository: HostingRepository
    private let transport: HostingTransport
    private var adapter: any HostingAPIAdapter {
        repository.provider == .github ? GitHubHostingAdapter(transport: transport) : GitLabHostingAdapter(transport: transport)
    }
    public init(repository: HostingRepository, cliPath: String, workingDirectory: URL,
                runner: @escaping HostingCommandRunner = HostingClient.liveRunner) {
        self.repository = repository
        transport = HostingTransport(repository: repository, cliPath: cliPath, directory: workingDirectory, runner: runner)
    }
    public static let liveRunner: HostingCommandRunner = HostingTransport.live
    public func diagnostics() async -> HostingDiagnostic {
        do {
            let user = try await transport.api("user")
            let login = user[repository.provider == .github ? "login" : "username"].string
            guard let login, !login.isEmpty else { throw HostingError.invalidResponse("The host did not identify the signed-in account.") }
            return HostingDiagnostic(host: repository.host, account: login, message: "Signed in as \(login) on \(repository.host)")
        } catch {
            return HostingDiagnostic(host: repository.host, account: nil, message: error.localizedDescription)
        }
    }
    /// Call immediately before executing a previewed mutation. CLI account
    /// switches outside RepoDeck must not silently change who posts the review.
    public func validateDestinationAndAccount(expectedID: String, expectedAccount: String?) async throws {
        guard repository.id == expectedID else { throw HostingError.unsupported("The destination changed. Preview the action again.") }
        let current = await diagnostics()
        guard let account = current.account, account == expectedAccount else {
            throw HostingError.unsupported("The hosting account changed or signed out. Reconnect and preview the action again.")
        }
    }
    public func list(page: Int = 1) async throws -> [ReviewRequest] {
        guard page > 0 else { throw HostingError.unsupported("Page numbers start at 1.") }
        return try await adapter.list(page: page, allStates: false)
    }
    /// Matches both the source project/fork and branch; names alone are ambiguous.
    public func matching(source: HostingRepository, branch: String) async throws -> [ReviewRequest] {
        var matches: [ReviewRequest] = []
        for page in 1...100 {
            let values = try await list(page: page)
            matches += values.filter { $0.matches(source: source, branch: branch, target: repository) }
            if values.count < 100 { return matches }
        }
        throw HostingError.invalidResponse("Too many open requests to identify a branch safely.")
    }
    public func detail(number: Int) async throws -> ReviewDetail {
        let request = try await adapter.request(number)
        var warnings: [String] = []
        var files: [ReviewFile] = []
        var comments: [ReviewComment] = []
        var checks: [ReviewCheck] = []
        do { files = try await adapter.files(number) } catch { warnings.append("Files: \(error.localizedDescription)") }
        do { comments = try await adapter.comments(number) } catch { warnings.append("Discussion: \(error.localizedDescription)") }
        do { checks = try await adapter.checks(request) } catch { warnings.append("Checks: \(error.localizedDescription)") }
        return ReviewDetail(request: request, files: files, comments: comments, checks: checks,
            capabilities: ReviewCapabilities(provider: repository.provider), warnings: warnings)
    }
    private func checked(_ number: Int, head: String) async throws -> ReviewRequest {
        guard number > 0, [40, 64].contains(head.count), head.allSatisfy(\.isHexDigit) else {
            throw HostingError.invalidResponse("A complete head commit is required for this action.")
        }
        let current = try await adapter.request(number)
        guard current.headOID == head else { throw HostingError.changedHead }
        return current
    }
    static func marker(_ id: UUID) -> String { "<!-- repodeck-operation:\(id.uuidString.lowercased()) -->" }
    private func findCreated(_ draft: ReviewDraft, marker: String) async throws -> ReviewRequest? {
        for page in 1...100 {
            let items = try await adapter.list(page: page, allStates: true)
            if let existing = items.first(where: { $0.body.contains(marker) }) {
                let expectedTitle = repository.provider == .gitlab && draft.isDraft && !draft.title.lowercased().hasPrefix("draft:")
                    ? "Draft: " + draft.title : draft.title
                guard existing.matches(source: draft.source, branch: draft.sourceBranch, target: repository),
                      existing.targetBranch == draft.targetBranch, existing.title == expectedTitle,
                      existing.body == draft.body + "\n\n" + marker else {
                    throw HostingError.unsupported("This operation identifier belongs to a different submitted draft. Inspect the earlier request before starting a new submission.")
                }
                return existing
            }
            if items.count < 100 { return nil }
        }
        throw HostingError.invalidResponse("Cannot safely check the entire request history for an earlier submission.")
    }
    public func create(_ draft: ReviewDraft, operationID: UUID) async throws -> ReviewRequest {
        guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !draft.sourceBranch.isEmpty, !draft.targetBranch.isEmpty,
              draft.source.host == repository.host, draft.source.provider == repository.provider else {
            throw HostingError.unsupported("Choose source and destination repositories on the same hosting service, two branches, and a title.")
        }
        let marker = Self.marker(operationID)
        if let prior = try await findCreated(draft, marker: marker) { return prior }
        do { return try await adapter.create(draft, body: draft.body + "\n\n" + marker) }
        catch {
            let original = error
            if let prior = try? await findCreated(draft, marker: marker) { return prior }
            throw HostingError.uncertain(original.localizedDescription)
        }
    }
    public func submit(number: Int, expectedHead: String, action: ReviewAction, body: String, operationID: UUID) async throws {
        guard action != .requestChanges || ReviewCapabilities(provider: repository.provider).requestChanges else {
            throw HostingError.unsupported("Formal change requests are unavailable for this provider; use a comment.")
        }
        guard action == .approve || !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HostingError.unsupported("Write a review message first.")
        }
        let current = try await checked(number, head: expectedHead)
        guard current.isOpen else { throw HostingError.unsupported("The request is no longer open.") }
        let marker = Self.marker(operationID)
        // A stable marker makes retries after timeouts safe across app restarts.
        let submittedBody = body + "\n\n" + marker
        if try await reconciledSubmission(number: number, marker: marker, body: submittedBody, action: action, head: expectedHead) { return }
        let account: String?
        if repository.provider == .gitlab, action == .approve {
            let diagnostic = await diagnostics()
            guard let login = diagnostic.account else { throw HostingError.unavailable(diagnostic.message) }
            account = login
            if try await adapter.hasApproved(current, account: login) { return }
        } else { account = nil }
        do { try await adapter.submit(current, action: action, body: submittedBody) }
        catch {
            let original = error
            if (try? await reconciledSubmission(number: number, marker: marker, body: submittedBody, action: action, head: expectedHead)) == true { return }
            if let account, (try? await adapter.hasApproved(current, account: account)) == true { return }
            throw HostingError.uncertain(original.localizedDescription)
        }
    }
    private func reconciledSubmission(number: Int, marker: String, body: String, action: ReviewAction, head: String) async throws -> Bool {
        guard let existing = try await adapter.comments(number).first(where: { $0.body.contains(marker) }) else { return false }
        let expectedState = action == .approve ? "APPROVED" : "CHANGES_REQUESTED"
        guard existing.body == body,
              action == .comment ? existing.state == nil : (existing.state == expectedState && existing.commitOID == head) else {
            throw HostingError.unsupported("This operation identifier belongs to a different submitted review. Inspect the earlier review before starting a new submission.")
        }
        return true
    }
    public func markReady(number: Int, expectedHead: String) async throws {
        let current = try await checked(number, head: expectedHead)
        guard current.isOpen else { throw HostingError.unsupported("The request is no longer open.") }
        guard current.isDraft else { return }
        do { try await adapter.ready(current) }
        catch {
            let original = error
            if let refreshed = try? await adapter.request(number), !refreshed.isDraft { return }
            throw HostingError.uncertain(original.localizedDescription)
        }
    }
    public func merge(number: Int, expectedHead: String, method: ReviewMergeMethod) async throws {
        let current = try await checked(number, head: expectedHead)
        if current.state == "merged" { return }
        guard current.isOpen, !current.isDraft else { throw HostingError.unsupported("Only an open, ready request can be merged.") }
        guard ReviewCapabilities(provider: repository.provider).mergeMethods.contains(method) else {
            throw HostingError.unsupported("This merge method is not supported by the provider.")
        }
        do { try await adapter.merge(current, method: method) }
        catch {
            let original = error
            if let refreshed = try? await adapter.request(number), refreshed.state == "merged" { return }
            throw HostingError.uncertain(original.localizedDescription)
        }
    }

    /// Fetch the provider's review ref into an isolated detached worktree. Never
    /// switches or rewrites the user's current branch, and checks the fetched OID.
    public func checkout(number: Int, expectedHead: String, to destination: URL, gitPath: String = GitDefaults.gitPath) async throws {
        _ = try await checked(number, head: expectedHead)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw HostingError.unsupported("Choose a new worktree directory; the destination already exists.")
        }
        let context = try await RepositoryContext.resolve(in: transport.directory, gitPath: gitPath)
        let key = context.commonGitDir.path
        try await RepositoryMutationCoordinator.shared.acquire(key)
        do {
            try await checkoutLocked(number: number, expectedHead: expectedHead, destination: destination, gitPath: gitPath)
            await RepositoryMutationCoordinator.shared.release(key)
        } catch {
            await RepositoryMutationCoordinator.shared.release(key)
            throw error
        }
    }
    private func git(_ arguments: [String], path: String) async throws -> String {
        let result = try await ProcessRunner.run(path, arguments: ["-C", transport.directory.path] + arguments,
            maxOutputBytes: 1_000_000, timeout: .seconds(120))
        guard result.exitCode == 0, !result.timedOut, !result.outputTruncated else {
            throw GitError(command: "git", exitCode: result.exitCode, stderr: result.stderr)
        }
        return String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func checkoutLocked(number: Int, expectedHead: String, destination: URL, gitPath: String) async throws {
        let remoteURL = try await git(["remote", "get-url", "--", repository.remoteName], path: gitPath)
        guard let current = HostingRepository.parse(remote: remoteURL, name: repository.remoteName, provider: repository.provider),
              current.host == repository.host, current.path == repository.path else {
            throw HostingError.unsupported("The selected remote changed or does not match the review destination. Refresh remotes before checkout.")
        }
        let ref = "refs/repodeck/reviews/" + UUID().uuidString.lowercased()
        let source = repository.provider == .github ? "refs/pull/\(number)/head" : "refs/merge-requests/\(number)/head"
        do {
            _ = try await git(["fetch", "--no-tags", "--no-write-fetch-head", "--", repository.remoteName, "\(source):\(ref)"], path: gitPath)
            let fetched = try await git(["rev-parse", "--verify", "\(ref)^{commit}"], path: gitPath)
            guard fetched == expectedHead else { throw HostingError.changedHead }
            _ = try await git(["worktree", "add", "--detach", "--", destination.path, fetched], path: gitPath)
            _ = try await git(["update-ref", "-d", ref], path: gitPath)
        } catch {
            _ = try? await git(["update-ref", "-d", ref], path: gitPath)
            throw error
        }
    }
    public static func remotes(in directory: URL, gitPath: String = GitDefaults.gitPath) async throws -> [(name: String, url: String)] {
        let names = try await ProcessRunner.run(gitPath, arguments: ["-C", directory.path, "remote"], timeout: .seconds(10))
        guard names.exitCode == 0 else { throw GitError(command: "git remote", exitCode: names.exitCode, stderr: names.stderr) }
        var result: [(String, String)] = []
        for name in String(decoding: names.stdout, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init) {
            let value = try await ProcessRunner.run(gitPath, arguments: ["-C", directory.path, "remote", "get-url", "--", name], timeout: .seconds(10))
            if value.exitCode == 0 { result.append((name, String(decoding: value.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))) }
        }
        return result
    }
    public static func discoverTool(_ provider: HostingProviderKind) -> String? {
        let directories = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        return directories.map { URL(fileURLWithPath: $0).appendingPathComponent(provider.toolName).path }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
