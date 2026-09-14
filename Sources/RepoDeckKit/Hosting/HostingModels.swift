import Foundation

public enum HostingProviderKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case github, gitlab
    public var id: String { rawValue }
    public var label: String { self == .github ? "GitHub" : "GitLab" }
    public var requestLabel: String { self == .github ? "Pull Request" : "Merge Request" }
    public var toolName: String { self == .github ? "gh" : "glab" }
}

public struct HostingRepository: Hashable, Codable, Sendable, Identifiable {
    public let provider: HostingProviderKind
    public let host: String
    public let path: String
    public let remoteName: String
    public var id: String { "\(provider.rawValue):\(host)/\(path)" }
    public var displayName: String { "\(host)/\(path)" }
    public init(provider: HostingProviderKind, host: String, path: String, remoteName: String = "origin") {
        self.provider = provider; self.host = host.lowercased(); self.path = path; self.remoteName = remoteName
    }
    /// Accept only network remotes. Credentials and SSH usernames are never retained.
    public static func parse(remote: String, name: String, provider: HostingProviderKind? = nil) -> HostingRepository? {
        let host: String
        var path: String
        if remote.contains("://"), let url = URLComponents(string: remote),
           ["https", "http", "ssh", "git"].contains(url.scheme ?? ""), let parsedHost = url.host {
            host = parsedHost + (url.port.map { ":\($0)" } ?? "")
            path = url.path
        } else if let colon = remote.firstIndex(of: ":"), !remote.hasPrefix("/"), !remote.contains("\\") {
            let authority = remote[..<colon]
            guard authority.contains("@") || authority.contains(".") else { return nil }
            host = String(authority.split(separator: "@").last ?? authority)
            path = String(remote[remote.index(after: colon)...])
        } else { return nil }
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.hasSuffix(".git") { path.removeLast(4) }
        guard !host.isEmpty, !host.hasPrefix("-"), !path.isEmpty,
              path.split(separator: "/").count >= 2,
              !path.split(separator: "/").contains(".."),
              !host.contains(where: { $0.isWhitespace }), !path.contains(where: { $0.isNewline }) else { return nil }
        let kind = provider ?? (host.lowercased() == "github.com" ? .github : host.lowercased() == "gitlab.com" ? .gitlab : nil)
        guard let kind else { return nil }
        return HostingRepository(provider: kind, host: host, path: path, remoteName: name)
    }
}

public struct HostingDiagnostic: Sendable, Equatable {
    public let host: String
    public let account: String?
    public let message: String
    public var isAuthenticated: Bool { account != nil }
    public init(host: String, account: String?, message: String) { self.host = host; self.account = account; self.message = message }
}

public enum ReviewAction: String, CaseIterable, Codable, Sendable, Identifiable {
    case comment, approve, requestChanges
    public var id: String { rawValue }
    public var label: String {
        switch self { case .comment: "Comment"; case .approve: "Approve"; case .requestChanges: "Request Changes" }
    }
}
public enum ReviewMergeMethod: String, CaseIterable, Sendable, Identifiable {
    case merge, squash, rebase
    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }
}
public struct ReviewCapabilities: Sendable, Equatable {
    public var requestChanges: Bool
    public var mergeMethods: [ReviewMergeMethod]
    public init(provider: HostingProviderKind) {
        requestChanges = provider == .github
        mergeMethods = provider == .github ? [.merge, .squash, .rebase] : [.merge, .squash]
    }
}
public struct ReviewRequest: Identifiable, Sendable, Equatable {
    public let number: Int
    public let title: String
    public let body: String
    public let url: URL
    public let author: String
    public let state: String
    public let isDraft: Bool
    public let sourceRepository: String
    public let sourceBranch: String
    public let targetBranch: String
    public let headOID: String
    public let sourceProjectID: Int?
    public let nodeID: String?
    public var id: Int { number }
    public var isOpen: Bool { state == "open" || state == "opened" }
    public func matches(source: HostingRepository, branch: String, target: HostingRepository) -> Bool {
        source.host == target.host && source.provider == target.provider
            && sourceRepository.caseInsensitiveCompare(source.path) == .orderedSame && sourceBranch == branch
    }
}
public struct ReviewFile: Identifiable, Sendable, Equatable {
    public let path: String
    public let previousPath: String?
    public let patch: String?
    public let status: String
    public var id: String { path }
}
public struct ReviewComment: Identifiable, Sendable, Equatable {
    public let id: String
    public let author: String
    public let body: String
    public let state: String?
    public let commitOID: String?
}
public struct ReviewCheck: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let status: String
    public let url: URL?
}
public struct ReviewDetail: Sendable, Equatable {
    public let request: ReviewRequest
    public let files: [ReviewFile]
    public let comments: [ReviewComment]
    public let checks: [ReviewCheck]
    public let capabilities: ReviewCapabilities
    /// A failed optional read is shown explicitly instead of impersonating an empty list.
    public let warnings: [String]
}
public struct ReviewDraft: Codable, Sendable, Equatable {
    public var title: String
    public var body: String
    public var source: HostingRepository
    public var sourceBranch: String
    public var targetBranch: String
    public var isDraft: Bool
    public init(title: String, body: String, source: HostingRepository, sourceBranch: String, targetBranch: String, isDraft: Bool = true) {
        self.title = title; self.body = body; self.source = source; self.sourceBranch = sourceBranch
        self.targetBranch = targetBranch; self.isDraft = isDraft
    }
}
public enum HostingError: Error, LocalizedError, Sendable, Equatable {
    case unavailable(String), invalidResponse(String), changedHead, unsupported(String), uncertain(String)
    public var errorDescription: String? {
        switch self {
        case .unavailable(let message), .invalidResponse(let message), .unsupported(let message): message
        case .changedHead: "The review's head commit changed. Refresh and review the new changes before retrying."
        case .uncertain(let message): "The server outcome could not be confirmed. \(message) Refresh before retrying; keep the same operation identifier."
        }
    }
}

public protocol HostingProviding: Sendable {
    var repository: HostingRepository { get }
    func diagnostics() async -> HostingDiagnostic
    func list(page: Int) async throws -> [ReviewRequest]
    func detail(number: Int) async throws -> ReviewDetail
    func create(_ draft: ReviewDraft, operationID: UUID) async throws -> ReviewRequest
    func submit(number: Int, expectedHead: String, action: ReviewAction, body: String, operationID: UUID) async throws
    func markReady(number: Int, expectedHead: String) async throws
    func merge(number: Int, expectedHead: String, method: ReviewMergeMethod) async throws
}

/// A submission receipt clears only the exact draft that was sent. Edits made
/// while awaiting the server remain available for the next review.
public struct ReviewTextDraft: Codable, Sendable, Equatable {
    public var body: String
    public var operationID: UUID
    public init(body: String = "", operationID: UUID = UUID()) { self.body = body; self.operationID = operationID }
    public mutating func didSubmit(body submittedBody: String, operationID submittedID: UUID) {
        guard operationID == submittedID else { return }
        if body == submittedBody { body = "" }
        operationID = UUID()
    }
}
