import Foundation

/// Serializes RepoDeck's writes to a shared Git directory. Git's own locks remain
/// authoritative for other applications; callers must still check fresh preconditions.
public actor RepositoryMutationCoordinator {
    public static let shared = RepositoryMutationCoordinator()
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    private var held: Set<String> = []
    private var waiters: [String: [Waiter]] = [:]

    public init() {}

    public func acquire(_ key: String) async throws {
        try Task.checkCancellation()
        if held.insert(key).inserted { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                waiters[key, default: []].append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancel(id, key: key) }
        }
        if Task.isCancelled {
            release(key)
            throw CancellationError()
        }
    }

    private func cancel(_ id: UUID, key: String) {
        guard let index = waiters[key]?.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters[key]!.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    public func release(_ key: String) {
        if var queue = waiters[key], !queue.isEmpty {
            let next = queue.removeFirst()
            waiters[key] = queue
            next.continuation.resume()
        } else {
            waiters.removeValue(forKey: key)
            held.remove(key)
        }
    }
}
