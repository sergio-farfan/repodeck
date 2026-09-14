import Foundation

typealias HJ = HostingJSON
protocol HostingAPIAdapter: Sendable {
    var transport: HostingTransport { get }
    func list(page: Int, allStates: Bool) async throws -> [ReviewRequest]
    func request(_ number: Int) async throws -> ReviewRequest
    func files(_ number: Int) async throws -> [ReviewFile]
    func comments(_ number: Int) async throws -> [ReviewComment]
    func checks(_ request: ReviewRequest) async throws -> [ReviewCheck]
    func create(_ draft: ReviewDraft, body: String) async throws -> ReviewRequest
    func submit(_ request: ReviewRequest, action: ReviewAction, body: String) async throws
    func ready(_ request: ReviewRequest) async throws
    func merge(_ request: ReviewRequest, method: ReviewMergeMethod) async throws
    func hasApproved(_ request: ReviewRequest, account: String) async throws -> Bool
}

struct GitHubHostingAdapter: HostingAPIAdapter {
    let transport: HostingTransport
    var base: String { "repos/" + transport.repository.path.split(separator: "/").map { hostingEncode(String($0)) }.joined(separator: "/") }
    func parse(_ value: HJ) throws -> ReviewRequest {
        guard let number = value["number"].int, number > 0,
              let url = URL(string: value["html_url"].text), let scheme = url.scheme, ["https", "http"].contains(scheme),
              !value["head"]["sha"].text.isEmpty else { throw HostingError.invalidResponse("Incomplete GitHub pull request response.") }
        return ReviewRequest(number: number, title: value["title"].text, body: value["body"].text,
            url: url, author: value["user"]["login"].text,
            state: value["merged"].bool || value["merged_at"].string != nil ? "merged" : value["state"].text,
            isDraft: value["draft"].bool, sourceRepository: value["head"]["repo"]["full_name"].text,
            sourceBranch: value["head"]["ref"].text, targetBranch: value["base"]["ref"].text,
            headOID: value["head"]["sha"].text, sourceProjectID: nil, nodeID: value["node_id"].string)
    }
    func list(page: Int, allStates: Bool) async throws -> [ReviewRequest] {
        let result = try await transport.api("\(base)/pulls?state=\(allStates ? "all" : "open")&per_page=100&page=\(page)")
        guard case .array(let values) = result else { throw HostingError.invalidResponse("Expected GitHub pull requests.") }
        return try values.map(parse)
    }
    func request(_ number: Int) async throws -> ReviewRequest { try parse(await transport.api("\(base)/pulls/\(number)")) }
    func files(_ number: Int) async throws -> [ReviewFile] {
        try await transport.pages("\(base)/pulls/\(number)/files").map {
            ReviewFile(path: $0["filename"].text, previousPath: $0["previous_filename"].string,
                patch: $0["patch"].string, status: $0["status"].text)
        }
    }
    func comments(_ number: Int) async throws -> [ReviewComment] {
        let discussion = try await transport.pages("\(base)/issues/\(number)/comments")
        let reviews = try await transport.pages("\(base)/pulls/\(number)/reviews")
        let inline = try await transport.pages("\(base)/pulls/\(number)/comments")
        return discussion.map { comment($0, id: "comment:\($0["id"].int ?? 0)") }
            + reviews.map { comment($0, id: "review:\($0["id"].int ?? 0)") }
            + inline.map { comment($0, id: "inline:\($0["id"].int ?? 0)") }
    }
    private func comment(_ value: HJ, id: String) -> ReviewComment {
        let location = value["path"].string.map { "\($0)\n" } ?? ""
        return ReviewComment(id: id, author: value["user"]["login"].text, body: location + value["body"].text,
            state: value["state"].string, commitOID: value["commit_id"].string)
    }
    func checks(_ request: ReviewRequest) async throws -> [ReviewCheck] {
        // A pull request can have checks on its head and on GitHub's synthetic
        // merge result. Both live in the destination repository, including forks.
        let before = try await transport.api("\(base)/pulls/\(request.number)")
        guard before["head"]["sha"].text == request.headOID else { throw HostingError.changedHead }
        let mergeOID = try testMergeOID(before)
        let baseOID = before["base"]["sha"].text
        var checks = try await checks(at: request.headOID, context: "Head")
        if let mergeOID, mergeOID != request.headOID {
            let commit = try await transport.api("\(base)/git/commits/\(hostingEncode(mergeOID))")
            let parents = commit["parents"].array.map { $0["sha"].text }
            guard parents.contains(request.headOID), baseOID.isEmpty || parents.contains(baseOID) else {
                throw HostingError.invalidResponse("The test merge no longer matches the reviewed head and base. Refresh the review before checking its results.")
            }
            checks += try await self.checks(at: mergeOID, context: "Test merge")
        }
        let after = try await transport.api("\(base)/pulls/\(request.number)")
        guard after["head"]["sha"].text == request.headOID else { throw HostingError.changedHead }
        guard try testMergeOID(after) == mergeOID, after["base"]["sha"].text == baseOID else {
            throw HostingError.invalidResponse("The pull request's base or test merge changed while loading checks. Refresh to see the current results.")
        }
        return checks
    }
    private func testMergeOID(_ value: HJ) throws -> String? {
        guard value["state"].text == "open", let oid = value["merge_commit_sha"].string else { return nil }
        guard [40, 64].contains(oid.count), oid.allSatisfy(\.isHexDigit) else {
            throw HostingError.invalidResponse("GitHub returned an invalid test-merge commit.")
        }
        return oid
    }
    private func checks(at oid: String, context: String) async throws -> [ReviewCheck] {
        let runs = try await transport.objectPages("\(base)/commits/\(hostingEncode(oid))/check-runs", key: "check_runs")
        let statuses = try await transport.objectPages("\(base)/commits/\(hostingEncode(oid))/status", key: "statuses")
        let checkRuns = runs.map {
            ReviewCheck(id: "\(context):check:\($0["id"].int ?? 0)", name: "\(context) · \($0["name"].text)",
                status: $0["conclusion"].string ?? $0["status"].text, url: URL(string: $0["html_url"].text))
        }
        return checkRuns + statuses.map {
            ReviewCheck(id: "\(context):status:\($0["id"].int ?? 0)", name: "\(context) · \($0["context"].text)",
                status: $0["state"].text, url: URL(string: $0["target_url"].text))
        }
    }
    func create(_ draft: ReviewDraft, body: String) async throws -> ReviewRequest {
        guard let owner = draft.source.path.split(separator: "/").first,
              let sourceRepo = draft.source.path.split(separator: "/").last else { throw HostingError.unsupported("Choose a source repository.") }
        return try parse(await transport.api("\(base)/pulls", method: "POST", body: [
            "title": .string(draft.title), "body": .string(body), "head": .string("\(owner):\(draft.sourceBranch)"),
            "head_repo": .string(String(sourceRepo)), "base": .string(draft.targetBranch), "draft": .bool(draft.isDraft)]))
    }
    func submit(_ request: ReviewRequest, action: ReviewAction, body: String) async throws {
        if action == .comment {
            _ = try await transport.api("\(base)/issues/\(request.number)/comments", method: "POST", body: ["body": .string(body)])
        } else {
            _ = try await transport.api("\(base)/pulls/\(request.number)/reviews", method: "POST", body: [
                "body": .string(body), "commit_id": .string(request.headOID),
                "event": .string(action == .approve ? "APPROVE" : "REQUEST_CHANGES")])
        }
    }
    func ready(_ request: ReviewRequest) async throws {
        guard let node = request.nodeID else { throw HostingError.invalidResponse("GitHub did not return the pull request node ID.") }
        let result = try await transport.api("graphql", method: "POST", body: [
            "query": .string("mutation($id:ID!){markPullRequestReadyForReview(input:{pullRequestId:$id}){pullRequest{isDraft}}}"),
            "variables": .object(["id": .string(node)])])
        guard result["errors"].array.isEmpty else { throw HostingError.unavailable("GitHub rejected marking the pull request ready.") }
        guard case .bool(false) = result["data"]["markPullRequestReadyForReview"]["pullRequest"]["isDraft"] else {
            throw HostingError.invalidResponse("GitHub did not confirm that the pull request is ready.")
        }
    }
    func merge(_ request: ReviewRequest, method: ReviewMergeMethod) async throws {
        let result = try await transport.api("\(base)/pulls/\(request.number)/merge", method: "PUT", body: [
            "sha": .string(request.headOID), "merge_method": .string(method.rawValue)])
        guard result["merged"].bool else { throw HostingError.unavailable(result["message"].string ?? "GitHub did not merge the pull request.") }
    }
    func hasApproved(_ request: ReviewRequest, account: String) async throws -> Bool {
        try await transport.pages("\(base)/pulls/\(request.number)/reviews").contains {
            $0["user"]["login"].text == account && $0["state"].text == "APPROVED" && $0["commit_id"].text == request.headOID
        }
    }
}

struct GitLabHostingAdapter: HostingAPIAdapter {
    let transport: HostingTransport
    var base: String { "projects/" + hostingEncode(transport.repository.path) }
    func parse(_ value: HJ, sourcePath: String) throws -> ReviewRequest {
        guard let number = value["iid"].int, number > 0, let url = URL(string: value["web_url"].text),
              let scheme = url.scheme, ["https", "http"].contains(scheme) else {
            throw HostingError.invalidResponse("Incomplete GitLab merge request response.")
        }
        return ReviewRequest(number: number, title: value["title"].text, body: value["description"].text,
            url: url, author: value["author"]["username"].text, state: value["state"].text,
            isDraft: value["draft"].bool || value["work_in_progress"].bool,
            sourceRepository: sourcePath, sourceBranch: value["source_branch"].text,
            targetBranch: value["target_branch"].text, headOID: value["sha"].text,
            sourceProjectID: value["source_project_id"].int, nodeID: nil)
    }
    func sourcePath(_ value: HJ) async throws -> String {
        guard let id = value["source_project_id"].int else { return "" }
        return try await transport.api("projects/\(id)")["path_with_namespace"].text
    }
    func list(page: Int, allStates: Bool) async throws -> [ReviewRequest] {
        let raw = try await transport.api("\(base)/merge_requests?state=\(allStates ? "all" : "opened")&scope=all&per_page=100&page=\(page)")
        guard case .array(let values) = raw else { throw HostingError.invalidResponse("Expected GitLab merge requests.") }
        var paths: [Int: String] = [:]
        var result: [ReviewRequest] = []
        for value in values {
            let sourceID = value["source_project_id"].int ?? -1
            let path: String
            if let cached = paths[sourceID] { path = cached }
            else { path = try await sourcePath(value); paths[sourceID] = path }
            result.append(try parse(value, sourcePath: path))
        }
        return result
    }
    func request(_ number: Int) async throws -> ReviewRequest {
        let value = try await transport.api("\(base)/merge_requests/\(number)")
        return try await parse(value, sourcePath: sourcePath(value))
    }
    func files(_ number: Int) async throws -> [ReviewFile] {
        try await transport.pages("\(base)/merge_requests/\(number)/diffs").map {
            ReviewFile(path: $0["new_path"].text, previousPath: $0["old_path"].string,
                patch: $0["too_large"].bool || $0["collapsed"].bool ? nil : $0["diff"].string,
                status: $0["new_file"].bool ? "added" : $0["deleted_file"].bool ? "deleted" : $0["renamed_file"].bool ? "renamed" : "modified")
        }
    }
    func comments(_ number: Int) async throws -> [ReviewComment] {
        try await transport.pages("\(base)/merge_requests/\(number)/notes?sort=asc").map {
            ReviewComment(id: "note:\($0["id"].int ?? 0)", author: $0["author"]["username"].text,
                body: $0["body"].text, state: $0["system"].bool ? "system" : nil, commitOID: nil)
        }
    }
    func checks(_ request: ReviewRequest) async throws -> [ReviewCheck] {
        let value = try await transport.api("\(base)/merge_requests/\(request.number)")
        let pipeline = value["head_pipeline"]
        guard let id = pipeline["id"].int else { return [] }
        return [ReviewCheck(id: "pipeline:\(id)", name: "Pipeline #\(id)", status: pipeline["status"].text,
            url: URL(string: pipeline["web_url"].text))]
    }
    func create(_ draft: ReviewDraft, body: String) async throws -> ReviewRequest {
        let target = try await transport.api(base)
        guard let targetID = target["id"].int else { throw HostingError.invalidResponse("GitLab did not return the destination project.") }
        let title = draft.isDraft && !draft.title.lowercased().hasPrefix("draft:") ? "Draft: " + draft.title : draft.title
        let result = try await transport.api("projects/\(hostingEncode(draft.source.path))/merge_requests", method: "POST", body: [
            "target_project_id": .number(Double(targetID)), "source_branch": .string(draft.sourceBranch),
            "target_branch": .string(draft.targetBranch), "title": .string(title), "description": .string(body)])
        return try parse(result, sourcePath: draft.source.path)
    }
    func submit(_ request: ReviewRequest, action: ReviewAction, body: String) async throws {
        switch action {
        case .comment:
            _ = try await transport.api("\(base)/merge_requests/\(request.number)/notes", method: "POST", body: ["body": .string(body)])
        case .approve:
            _ = try await transport.api("\(base)/merge_requests/\(request.number)/approve", method: "POST", body: ["sha": .string(request.headOID)])
        case .requestChanges:
            throw HostingError.unsupported("This GitLab adapter does not expose a formal request-changes API. Publish a review comment instead.")
        }
    }
    func ready(_ request: ReviewRequest) async throws {
        let title = request.title.replacingOccurrences(of: #"^(Draft:|WIP:|\[Draft\]|\(Draft\))\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
        let result = try await transport.api("\(base)/merge_requests/\(request.number)", method: "PUT", body: ["title": .string(title)])
        guard !result["draft"].bool && !result["work_in_progress"].bool else { throw HostingError.unavailable("GitLab did not mark the merge request ready.") }
    }
    func merge(_ request: ReviewRequest, method: ReviewMergeMethod) async throws {
        guard method != .rebase else { throw HostingError.unsupported("GitLab's merge strategy is configured by the project; choose Merge or Squash.") }
        let result = try await transport.api("\(base)/merge_requests/\(request.number)/merge", method: "PUT", body: [
            "sha": .string(request.headOID), "squash": .bool(method == .squash), "should_remove_source_branch": .bool(false)])
        guard result["state"].text == "merged" else { throw HostingError.unavailable(result["merge_error"].string ?? "GitLab did not confirm the merge.") }
    }
    func hasApproved(_ request: ReviewRequest, account: String) async throws -> Bool {
        let value = try await transport.api("\(base)/merge_requests/\(request.number)/approvals")
        return value["approved_by"].array.contains { $0["user"]["username"].text == account }
    }
}
