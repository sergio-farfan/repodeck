import Foundation
import Testing
@testable import RepoDeckKit

private let reviewHead = String(repeating: "a", count: 40)
private let otherHead = String(repeating: "b", count: 40)
private func githubRequest(number: Int = 7, source: String = "alice/app", body: String = "description", head: String = reviewHead, draft: Bool = false) -> HJ {
    .object(["number": .number(Double(number)), "title": .string("Feature"), "body": .string(body),
        "html_url": .string("https://github.example/acme/app/pull/\(number)"), "node_id": .string("PR_7"),
        "user": .object(["login": .string("alice")]), "state": .string("open"), "draft": .bool(draft),
        "head": .object(["sha": .string(head), "ref": .string("feature"), "repo": .object(["full_name": .string(source)])]),
        "base": .object(["ref": .string("main")])])
}
private func gitlabRequest(sourceID: Int = 9, body: String = "description") -> HJ {
    .object(["iid": .number(7), "title": .string("Feature"), "description": .string(body),
        "web_url": .string("https://gitlab.example/group/app/-/merge_requests/7"), "sha": .string(reviewHead),
        "source_project_id": .number(Double(sourceID)), "source_branch": .string("feature"), "target_branch": .string("main"),
        "author": .object(["username": .string("alice")]), "state": .string("opened"), "draft": .bool(false)])
}
private func result(_ value: HJ) throws -> ProcessResult {
    ProcessResult(exitCode: 0, stdout: try JSONEncoder().encode(value), stderr: "", outputTruncated: false)
}
private actor HostingFake {
    var calls: [HostingCommand] = []
    var request: HJ = githubRequest()
    var requests: [HJ] = []
    var comments: [HJ] = []
    var loseWriteResponse = false
    var approved = false
    var gitlab = false
    var failFiles = false
    var expiredHosts: Set<String> = []
    var writeRejection: String?
    func configure(request: HJ? = nil, requests: [HJ]? = nil, loseResponse: Bool = false, gitlab: Bool = false, failFiles: Bool = false) {
        if let request { self.request = request }
        if let requests { self.requests = requests }
        loseWriteResponse = loseResponse; self.gitlab = gitlab; self.failFiles = failFiles
    }
    func setCredentialsExpired(_ expired: Bool, host: String) {
        if expired { expiredHosts.insert(host) } else { expiredHosts.remove(host) }
    }
    func rejectWrites(message: String) { writeRejection = message }
    func snapshot() -> [HostingCommand] { calls }
    func run(_ command: HostingCommand) throws -> ProcessResult {
        calls.append(command)
        let host = command.arguments[2]
        let endpoint = command.arguments[5]
        let method = command.arguments[4]
        if expiredHosts.contains(host) {
            return ProcessResult(exitCode: 1, stdout: Data(), stderr: "Credentials expired (HTTP 401)", outputTruncated: false)
        }
        if method != "GET", let writeRejection {
            return ProcessResult(exitCode: 1, stdout: Data(), stderr: writeRejection, outputTruncated: false)
        }
        let payload = try command.input.map { try JSONDecoder().decode(HJ.self, from: $0) } ?? .null
        if endpoint == "user" { return try result(.object([gitlab ? "username" : "login": .string("tester")])) }
        if endpoint == "projects/9" { return try result(.object(["path_with_namespace": .string("alice/app")])) }
        if endpoint == "projects/10" { return try result(.object(["path_with_namespace": .string("bob/app")])) }
        if method == "POST", endpoint.hasSuffix("/pulls") {
            request = githubRequest(body: payload["body"].text)
            requests.append(request)
            return try writeResult(request)
        }
        if method == "POST", endpoint.hasSuffix("/comments") || endpoint.hasSuffix("/notes") || endpoint.hasSuffix("/reviews") {
            let comment = HJ.object(["id": .number(88), "body": payload["body"], "user": .object(["login": .string("tester")])])
            comments.append(comment)
            return try writeResult(comment)
        }
        if method == "POST", endpoint.hasSuffix("/approve") { approved = true; return try writeResult(.object([:])) }
        if endpoint.hasSuffix("/approvals") {
            return try result(.object(["approved_by": .array(approved ? [.object(["user": .object(["username": .string("tester")])])] : [])]))
        }
        if method == "PUT", endpoint.hasSuffix("/merge") { return try result(.object(["merged": .bool(true), "state": .string("merged")])) }
        if endpoint.contains("/pulls?"), method == "GET" { return try result(.array(requests)) }
        if endpoint.contains("/merge_requests?"), method == "GET" { return try result(.array(requests)) }
        if endpoint.hasSuffix("/pulls/7") || endpoint.hasSuffix("/merge_requests/7") { return try result(request) }
        if endpoint.contains("/files?") && failFiles { throw HostingError.unavailable("Files unavailable") }
        if endpoint.contains("/issues/7/comments?") || endpoint.contains("/notes?") { return try result(.array(comments)) }
        if endpoint.contains("/check-runs?") { return try result(.object(["check_runs": .array([])])) }
        if endpoint.contains("/status?") { return try result(.object(["statuses": .array([])])) }
        return try result(.array([]))
    }
    private func writeResult(_ value: HJ) throws -> ProcessResult {
        if loseWriteResponse { return ProcessResult(exitCode: 1, stdout: Data(), stderr: "connection lost after upload", outputTruncated: false) }
        return try result(value)
    }
}
private func client(_ fake: HostingFake, provider: HostingProviderKind = .github, host: String? = nil) -> HostingClient {
    HostingClient(repository: HostingRepository(provider: provider, host: host ?? (provider == .github ? "github.example" : "gitlab.example"), path: "acme/app"),
        cliPath: "/fake/tool", workingDirectory: URL(fileURLWithPath: "/private/tmp"), runner: { try await fake.run($0) })
}

private actor GitHubChecksFixture {
    enum Scenario: Sendable, CaseIterable { case stable, staleParent, changedHead, changedMerge, unreadableMerge }
    let scenario: Scenario
    private var requestReads = 0
    init(_ scenario: Scenario) { self.scenario = scenario }
    func run(_ command: HostingCommand) throws -> ProcessResult {
        let endpoint = command.arguments[5]
        if endpoint.hasSuffix("/pulls/7") {
            requestReads += 1
            let changed = requestReads >= 3
            guard case .object(var value) = githubRequest(source: "contributor/fork", head: changed && scenario == .changedHead ? otherHead : reviewHead) else { fatalError() }
            value["merge_commit_sha"] = .string(changed && scenario == .changedMerge ? String(repeating: "d", count: 40) : otherHead)
            return try result(.object(value))
        }
        if endpoint == "repos/acme/app/git/commits/\(otherHead)" {
            return try result(.object(["parents": .array([.object([
                "sha": .string(scenario == .staleParent ? String(repeating: "c", count: 40) : reviewHead)])])]))
        }
        if endpoint.contains("/check-runs?") {
            #expect(endpoint.hasPrefix("repos/acme/app/commits/"))
            let isMerge = endpoint.contains(otherHead)
            if isMerge && scenario == .unreadableMerge {
                return ProcessResult(exitCode: 1, stdout: Data(), stderr: "Merge checks unavailable (HTTP 403)", outputTruncated: false)
            }
            return try result(.object(["check_runs": .array([.object([
                "id": .number(isMerge ? 2 : 1), "name": .string("CI"),
                "conclusion": .string(isMerge ? "failure" : "success")])])]))
        }
        if endpoint.contains("/status?") { return try result(.object(["statuses": .array([])])) }
        return try result(.array([]))
    }
}

@Suite struct HostingClientTests {
    @Test func parsesNestedGitLabAndDropsCredentials() {
        let remote = HostingRepository.parse(remote: "https://name:secret@gitlab.example/group/subgroup/app.git", name: "upstream", provider: .gitlab)
        #expect(remote?.host == "gitlab.example")
        #expect(remote?.path == "group/subgroup/app")
        #expect(remote?.remoteName == "upstream")
        #expect(remote?.displayName.contains("secret") == false)
        #expect(HostingRepository.parse(remote: "git@github.com:alice/app.git", name: "origin")?.path == "alice/app")
        #expect(HostingRepository.parse(remote: "/tmp/repo.git", name: "origin") == nil)
        #expect(HostingRepository.parse(remote: "ssh://git@custom.example/team/app.git", name: "origin") == nil)
    }
    @Test func branchMatchingIncludesTheFork() async throws {
        let fake = HostingFake()
        await fake.configure(requests: [githubRequest(number: 1, source: "bob/app"), githubRequest(number: 2, source: "alice/app")])
        let source = HostingRepository(provider: .github, host: "github.example", path: "alice/app")
        let found = try await client(fake).matching(source: source, branch: "feature")
        #expect(found.map(\.number) == [2])
    }
    @Test func gitlabResolvesSourceProjectInsteadOfAssumingTarget() async throws {
        let fake = HostingFake()
        await fake.configure(requests: [gitlabRequest(sourceID: 9), gitlabRequest(sourceID: 10)], gitlab: true)
        let values = try await client(fake, provider: .gitlab).list()
        #expect(values.map(\.sourceRepository) == ["alice/app", "bob/app"])
        let calls = await fake.snapshot()
        #expect(calls[0].arguments.contains("projects/acme%2Fapp/merge_requests?state=opened&scope=all&per_page=100&page=1"))
    }
    @Test func diagnosticsAreScopedToHostAndAccount() async {
        let fake = HostingFake()
        let diagnostic = await client(fake).diagnostics()
        #expect(diagnostic.account == "tester")
        #expect(diagnostic.host == "github.example")
        let calls = await fake.snapshot()
        #expect(calls.first?.arguments == ["api", "--hostname", "github.example", "--method", "GET", "user"])
    }
    @Test(arguments: HostingProviderKind.allCases)
    func expiredCredentialsStayHostScopedAndExplicitRetrySucceeds(provider: HostingProviderKind) async throws {
        let fake = HostingFake()
        let request = provider == .github ? githubRequest() : gitlabRequest()
        await fake.configure(request: request, requests: [request], gitlab: provider == .gitlab)
        let expired = client(fake, provider: provider, host: "expired.\(provider.rawValue).example")
        let healthy = client(fake, provider: provider)
        await fake.setCredentialsExpired(true, host: expired.repository.host)
        let original = ReviewTextDraft(body: "Keep this review while credentials are renewed.")
        var draft = original

        let failedDiagnostic = await expired.diagnostics()
        #expect(failedDiagnostic.host == expired.repository.host)
        #expect(failedDiagnostic.account == nil)
        #expect(failedDiagnostic.message.contains("Credentials expired (HTTP 401)"))
        do {
            try await expired.submit(number: 7, expectedHead: reviewHead, action: .comment,
                body: original.body, operationID: original.operationID)
            draft.didSubmit(body: original.body, operationID: original.operationID)
            Issue.record("Expected expired-credential failure")
        } catch {
            #expect(error.localizedDescription.contains(expired.repository.host))
            #expect(error.localizedDescription.contains("Credentials expired (HTTP 401)"))
        }
        #expect(draft == original)

        let healthyDiagnostic = await healthy.diagnostics()
        #expect(healthyDiagnostic.host == healthy.repository.host)
        #expect(healthyDiagnostic.account == "tester")
        #expect(try await healthy.list().map(\.number) == [7])
        let failedHostCalls = await fake.snapshot().filter { $0.arguments[2] == expired.repository.host }
        #expect(failedHostCalls.count == 2)
        #expect(failedHostCalls.allSatisfy { $0.arguments[4] == "GET" })

        // Renew only this host's credentials, then explicitly retry the same draft.
        await fake.setCredentialsExpired(false, host: expired.repository.host)
        #expect(await expired.diagnostics().account == "tester")
        try await expired.submit(number: 7, expectedHead: reviewHead, action: .comment,
            body: original.body, operationID: original.operationID)
        draft.didSubmit(body: original.body, operationID: original.operationID)
        #expect(draft.body.isEmpty)
        #expect(draft.operationID != original.operationID)
        let writes = await fake.snapshot().filter { $0.arguments[4] != "GET" }
        #expect(writes.count == 1)
        #expect(writes.first?.arguments[2] == expired.repository.host)
    }
    @Test(arguments: HostingProviderKind.allCases)
    func forbiddenMergeRetainsProtectionErrorWithoutRepeatingWrite(provider: HostingProviderKind) async throws {
        let fake = HostingFake()
        await fake.configure(request: provider == .github ? githubRequest() : gitlabRequest(), gitlab: provider == .gitlab)
        let message = "Merge rejected: protected branch requires approval (HTTP 403)"
        await fake.rejectWrites(message: message)
        let api = client(fake, provider: provider)

        do {
            try await api.merge(number: 7, expectedHead: reviewHead, method: .squash)
            Issue.record("Expected branch-protection rejection")
        } catch {
            #expect(error as? HostingError == .uncertain("\(api.repository.host): \(message)"))
            #expect(error.localizedDescription.contains(message))
        }
        let calls = await fake.snapshot()
        let writes = calls.filter { $0.arguments[4] != "GET" }
        #expect(writes.count == 1)
        #expect(writes.first?.arguments[4] == "PUT")
        #expect(writes.first?.arguments[5].hasSuffix("/merge") == true)
        let writeIndex = try #require(calls.firstIndex { $0.arguments[4] != "GET" })
        #expect(writeIndex < calls.count - 1)
        #expect(calls.dropFirst(writeIndex + 1).allSatisfy { $0.arguments[4] == "GET" })
    }
    @Test(arguments: HostingProviderKind.allCases, [ReviewAction.comment, .approve])
    func forbiddenReviewKeepsDraftAndServerErrorWithoutRepeatingWrite(provider: HostingProviderKind, action: ReviewAction) async throws {
        let fake = HostingFake()
        await fake.configure(request: provider == .github ? githubRequest() : gitlabRequest(), gitlab: provider == .gitlab)
        let message = "Review rejected: account lacks permission (HTTP 403)"
        await fake.rejectWrites(message: message)
        let api = client(fake, provider: provider)
        let original = ReviewTextDraft(body: "Review text that must survive a rejected submission.")
        var draft = original

        do {
            try await api.submit(number: 7, expectedHead: reviewHead, action: action,
                body: original.body, operationID: original.operationID)
            draft.didSubmit(body: original.body, operationID: original.operationID)
            Issue.record("Expected review-permission rejection")
        } catch {
            #expect(error as? HostingError == .uncertain("\(api.repository.host): \(message)"))
            #expect(error.localizedDescription.contains(message))
        }
        #expect(draft.body == original.body)
        #expect(draft.operationID == original.operationID)
        let calls = await fake.snapshot()
        let writes = calls.filter { $0.arguments[4] != "GET" }
        #expect(writes.count == 1)
        #expect(writes.first?.arguments[4] == "POST")
        let writeIndex = try #require(calls.firstIndex { $0.arguments[4] != "GET" })
        #expect(writeIndex < calls.count - 1)
        #expect(calls.dropFirst(writeIndex + 1).allSatisfy { $0.arguments[4] == "GET" })
    }
    @Test func staleHeadNeverSendsAMutation() async throws {
        let fake = HostingFake()
        await fake.configure(request: githubRequest(head: otherHead))
        await #expect(throws: HostingError.changedHead) {
            try await client(fake).merge(number: 7, expectedHead: reviewHead, method: .squash)
        }
        #expect(await fake.snapshot().allSatisfy { $0.arguments[4] == "GET" })
    }
    @Test func mergeSendsExpectedHeadAndSelectedMethod() async throws {
        let fake = HostingFake()
        try await client(fake).merge(number: 7, expectedHead: reviewHead, method: .squash)
        let mutation = try #require(await fake.snapshot().last)
        let body = try JSONDecoder().decode(HJ.self, from: #require(mutation.input))
        #expect(body["sha"].text == reviewHead)
        #expect(body["merge_method"].text == "squash")
        #expect(mutation.arguments[5] == "repos/acme/app/pulls/7/merge")
    }
    @Test func lostCreationResponseReconcilesWithoutDuplicateSubmission() async throws {
        let fake = HostingFake()
        await fake.configure(loseResponse: true)
        let api = client(fake)
        let draft = ReviewDraft(title: "Feature", body: "Multiline\nbody `literal` $HOME", source: HostingRepository(provider: .github, host: "github.example", path: "alice/app"), sourceBranch: "feature", targetBranch: "main")
        let id = UUID()
        let first = try await api.create(draft, operationID: id)
        let second = try await api.create(draft, operationID: id)
        #expect(first.number == second.number)
        let calls = await fake.snapshot()
        #expect(calls.filter { $0.arguments[4] == "POST" }.count == 1)
        let post = try #require(calls.first { $0.arguments[4] == "POST" })
        let body = try JSONDecoder().decode(HJ.self, from: #require(post.input))
        #expect(body["body"].text.hasPrefix(draft.body))
        #expect(body["head"].text == "alice:feature")
        #expect(body["head_repo"].text == "app")
    }
    @Test func lostCommentResponseReconcilesAndRetryDoesNotPostAgain() async throws {
        let fake = HostingFake()
        await fake.configure(loseResponse: true)
        let api = client(fake)
        let id = UUID()
        try await api.submit(number: 7, expectedHead: reviewHead, action: .comment, body: "Please add a test.", operationID: id)
        try await api.submit(number: 7, expectedHead: reviewHead, action: .comment, body: "Please add a test.", operationID: id)
        #expect(await fake.snapshot().filter { $0.arguments[4] == "POST" }.count == 1)
    }
    @Test func gitlabApprovalUsesShaAndReconcilesLostResponse() async throws {
        let fake = HostingFake()
        await fake.configure(request: gitlabRequest(), loseResponse: true, gitlab: true)
        try await client(fake, provider: .gitlab).submit(number: 7, expectedHead: reviewHead, action: .approve, body: "", operationID: UUID())
        let calls = await fake.snapshot()
        let approval = try #require(calls.first { $0.arguments[4] == "POST" })
        let body = try JSONDecoder().decode(HJ.self, from: #require(approval.input))
        #expect(body["sha"].text == reviewHead)
        #expect(calls.filter { $0.arguments[4] == "POST" }.count == 1)
    }
    @Test func unsupportedGitLabRequestChangesDoesNotCallServer() async {
        let fake = HostingFake()
        do { try await client(fake, provider: .gitlab).submit(number: 7, expectedHead: reviewHead, action: .requestChanges, body: "Fix this", operationID: UUID()); Issue.record("Expected unsupported error") }
        catch { #expect(error is HostingError) }
        #expect(await fake.snapshot().isEmpty)
    }
    @Test func failedFileReadIsReportedSeparatelyFromEmptyFiles() async throws {
        let fake = HostingFake()
        await fake.configure(failFiles: true)
        let detail = try await client(fake).detail(number: 7)
        #expect(detail.files.isEmpty)
        #expect(detail.warnings.contains { $0.contains("Files unavailable") })
    }
    @Test func forkReviewReadsChecksFromDestinationAtReviewedHead() async throws {
        let repository = HostingRepository(provider: .github, host: "github.example", path: "acme/app")
        let api = HostingClient(repository: repository, cliPath: "/fake/tool", workingDirectory: URL(fileURLWithPath: "/private/tmp"), runner: { command in
            let endpoint = command.arguments[5]
            if endpoint.hasSuffix("/pulls/7") { return try result(githubRequest(source: "contributor/fork")) }
            if endpoint.contains("/check-runs?") {
                #expect(endpoint.hasPrefix("repos/acme/app/commits/\(reviewHead)/check-runs?"))
                return try result(.object(["check_runs": .array([.object([
                    "id": .number(10), "name": .string("Required base CI"), "conclusion": .string("failure")])])]))
            }
            if endpoint.contains("/status?") {
                #expect(endpoint.hasPrefix("repos/acme/app/commits/\(reviewHead)/status?"))
                return try result(.object(["statuses": .array([])]))
            }
            return try result(.array([]))
        })
        let detail = try await api.detail(number: 7)
        #expect(detail.request.sourceRepository == "contributor/fork")
        #expect(detail.checks.first?.name == "Head · Required base CI")
        #expect(detail.checks.first?.status == "failure")
        #expect(detail.warnings.isEmpty)
    }
    @Test func syntheticMergeChecksRemainVisibleBesideHeadChecks() async throws {
        let fake = GitHubChecksFixture(.stable)
        let api = HostingClient(repository: HostingRepository(provider: .github, host: "github.example", path: "acme/app"),
            cliPath: "/fake/tool", workingDirectory: URL(fileURLWithPath: "/private/tmp"), runner: { try await fake.run($0) })
        let detail = try await api.detail(number: 7)
        #expect(detail.checks.map(\.name) == ["Head · CI", "Test merge · CI"])
        #expect(detail.checks.map(\.status) == ["success", "failure"])
        #expect(detail.warnings.isEmpty)
    }
    @Test(arguments: [GitHubChecksFixture.Scenario.staleParent, .changedHead, .changedMerge, .unreadableMerge])
    private func staleOrUnreadableMergeChecksDoNotLeaveAnApparentlyPassingHead(scenario: GitHubChecksFixture.Scenario) async throws {
        let fake = GitHubChecksFixture(scenario)
        let api = HostingClient(repository: HostingRepository(provider: .github, host: "github.example", path: "acme/app"),
            cliPath: "/fake/tool", workingDirectory: URL(fileURLWithPath: "/private/tmp"), runner: { try await fake.run($0) })
        let detail = try await api.detail(number: 7)
        #expect(detail.checks.isEmpty)
        #expect(detail.warnings.count == 1)
        #expect(detail.warnings[0].hasPrefix("Checks:"))
        if scenario == .unreadableMerge { #expect(detail.warnings[0].contains("HTTP 403")) }
        if scenario == .changedHead { #expect(detail.warnings[0].contains("head commit changed")) }
        if scenario == .changedMerge { #expect(detail.warnings[0].contains("test merge changed")) }
        if scenario == .staleParent { #expect(detail.warnings[0].contains("no longer matches")) }
    }
    @Test func reusedCreationIDWithChangedContentNeverWritesAgain() async throws {
        let fake = HostingFake()
        let api = client(fake)
        let id = UUID()
        var draft = ReviewDraft(title: "Feature", body: "First body", source: HostingRepository(provider: .github, host: "github.example", path: "alice/app"), sourceBranch: "feature", targetBranch: "main")
        _ = try await api.create(draft, operationID: id)
        draft.body = "A different body"
        do { _ = try await api.create(draft, operationID: id); Issue.record("Expected reused-operation refusal") }
        catch { #expect(error.localizedDescription.contains("different submitted draft")) }
        #expect(await fake.snapshot().filter { $0.arguments[4] == "POST" }.count == 1)
    }
    @Test func reusedCommentIDWithChangedContentOrActionNeverWritesAgain() async throws {
        let fake = HostingFake()
        let api = client(fake)
        let id = UUID()
        try await api.submit(number: 7, expectedHead: reviewHead, action: .comment, body: "First", operationID: id)
        for (action, body) in [(ReviewAction.comment, "Changed"), (.approve, "First")] {
            do { try await api.submit(number: 7, expectedHead: reviewHead, action: action, body: body, operationID: id); Issue.record("Expected reused-operation refusal") }
            catch { #expect(error.localizedDescription.contains("different submitted review")) }
        }
        #expect(await fake.snapshot().filter { $0.arguments[4] == "POST" }.count == 1)
    }
    @Test func accountSwitchRejectsPreviewWithoutMutationAndKeepsDraft() async throws {
        let fake = HostingFake()
        let api = client(fake)
        let id = UUID()
        let draft = ReviewTextDraft(body: "Unsent review", operationID: id)
        do {
            try await api.validateDestinationAndAccount(expectedID: api.repository.id, expectedAccount: "previous-account")
            Issue.record("Expected account-change refusal")
        } catch { #expect(error.localizedDescription.contains("account changed")) }
        #expect(await fake.snapshot().allSatisfy { $0.arguments[4] == "GET" })
        #expect(draft.body == "Unsent review")
        #expect(draft.operationID == id)
    }
    @Test func successfulReceiptPreservesEditsMadeDuringSubmission() {
        let id = UUID()
        var draft = ReviewTextDraft(body: "First message", operationID: id)
        draft.body = "New message typed during network request"
        draft.didSubmit(body: "First message", operationID: id)
        #expect(draft.body == "New message typed during network request")
        #expect(draft.operationID != id)
        let newID = draft.operationID
        draft.didSubmit(body: draft.body, operationID: id)
        #expect(draft.operationID == newID)
        #expect(!draft.body.isEmpty)
        draft.didSubmit(body: draft.body, operationID: newID)
        #expect(draft.body.isEmpty)
    }
    @Test func gitlabPreparingRequestCanHaveNoHeadYet() async throws {
        let fake = HostingFake()
        let api = client(fake, provider: .gitlab)
        let raw = gitlabRequest()
        guard case .object(var values) = raw else { return }
        values["sha"] = .null
        await fake.configure(request: .object(values), requests: [.object(values)], gitlab: true)
        let items = try await api.list()
        #expect(items.first?.headOID == "")
        do { try await api.merge(number: 7, expectedHead: "", method: .merge); Issue.record("Expected incomplete-head refusal") }
        catch { #expect(error.localizedDescription.contains("complete head")) }
        #expect(await fake.snapshot().allSatisfy { $0.arguments[4] == "GET" })
    }
    @Test func fakeExecutableUsesExplicitHostnameWithoutRealNetwork() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("HostingCLI-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let tool = dir.appendingPathComponent("gh")
        try "#!/bin/sh\n[ \"$1\" = api ] && [ \"$2\" = --hostname ] && [ \"$3\" = github.example ] || exit 19\nprintf '%s' '{\"login\":\"fake-account\"}'\n".write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        let api = HostingClient(repository: HostingRepository(provider: .github, host: "github.example", path: "acme/app"), cliPath: tool.path, workingDirectory: dir)
        let diagnostic = await api.diagnostics()
        #expect(diagnostic.account == "fake-account")
    }
}

@Suite struct ReviewCheckoutTests {
    private func git(_ args: [String], in directory: URL) async throws -> String {
        let result = try await ProcessRunner.run("/usr/bin/git", arguments: ["-C", directory.path] + args,
            environment: ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_AUTHOR_NAME": "Tests",
                "GIT_AUTHOR_EMAIL": "tests@example.invalid", "GIT_COMMITTER_NAME": "Tests", "GIT_COMMITTER_EMAIL": "tests@example.invalid"])
        guard result.exitCode == 0 else { throw GitError(command: "test git", exitCode: result.exitCode, stderr: result.stderr) }
        return String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    @Test func checkoutCreatesDetachedWorktreeAndPreservesDirtyCheckout() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ReviewCheckout-\(UUID())")
        let repo = root.appendingPathComponent("repo")
        let server = root.appendingPathComponent("server.git")
        let destination = root.appendingPathComponent("review")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await TestGitRepository.initialize(at: repo)
        try "base\n".write(to: repo.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        _ = try await git(["add", "file.txt"], in: repo)
        _ = try await git(["commit", "-qm", "Base"], in: repo)
        let head = try await git(["rev-parse", "HEAD"], in: repo)
        try await TestGitRepository.initialize(at: server, bare: true)
        _ = try await git(["remote", "add", "origin", server.path], in: repo)
        _ = try await git(["push", "origin", "HEAD:refs/pull/7/head"], in: repo)
        try "uncommitted\n".write(to: repo.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        // Keep transport fully local; only discovery receives a simulated hosting URL.
        let gitWrapper = root.appendingPathComponent("git-wrapper")
        try "#!/bin/sh\nif [ \"$3\" = remote ] && [ \"$4\" = get-url ]; then\n  printf '%s\\n' 'https://github.example/acme/app.git'\nelse\n  exec /usr/bin/git \"$@\"\nfi\n".write(to: gitWrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gitWrapper.path)
        let fake = HostingFake()
        await fake.configure(request: githubRequest(head: head))
        let api = HostingClient(repository: HostingRepository(provider: .github, host: "github.example", path: "acme/app"),
            cliPath: "/fake/gh", workingDirectory: repo, runner: { try await fake.run($0) })
        try await api.checkout(number: 7, expectedHead: head, to: destination, gitPath: gitWrapper.path)
        #expect(try await git(["symbolic-ref", "--short", "HEAD"], in: repo) == "main")
        #expect(try String(contentsOf: repo.appendingPathComponent("file.txt"), encoding: .utf8) == "uncommitted\n")
        #expect(try await git(["rev-parse", "HEAD"], in: destination) == head)
        #expect(try await git(["for-each-ref", "--format=%(refname)", "refs/repodeck/reviews"], in: repo).isEmpty)
        let detached = try await ProcessRunner.run("/usr/bin/git", arguments: ["-C", destination.path, "symbolic-ref", "-q", "HEAD"])
        #expect(detached.exitCode != 0)
    }
}
