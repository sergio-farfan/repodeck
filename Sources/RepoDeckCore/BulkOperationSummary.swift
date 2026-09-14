import Foundation
import RepoDeckKit

/// Retains the results of one run even after a repository's live status changes.
public struct BulkOperationSummary: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let operation: String
    public let repositories: [RepositoryResult]

    public struct RepositoryResult: Identifiable, Sendable, Equatable {
        public let id: String
        public let name: String
        public let path: URL
        public let result: OperationResult

        public init(id: String, name: String, path: URL, result: OperationResult) {
            self.id = id; self.name = name; self.path = path; self.result = result
        }
    }

    public init(operation: String, repositories: [RepositoryResult]) {
        self.id = UUID()
        self.operation = operation
        self.repositories = repositories
    }

    public var succeeded: Int { repositories.filter { $0.result == .succeeded }.count }
    public var failed: Int { repositories.filter { if case .failed = $0.result { true } else { false } }.count }
    public var skipped: Int { repositories.count - succeeded - failed }
    public var needsAttention: Bool { failed > 0 || skipped > 0 }
    public var text: String { "\(operation): \(succeeded) succeeded, \(failed) failed, \(skipped) skipped" }
}
