import Foundation
import Observation
import RepoDeckKit

/// Selection and drafts live with the worktree, independently of mounted views.
@MainActor @Observable
public final class RepositoryWorkspaceModel {
    public var branches: [BranchInfo] = []
    public var worktrees: [WorktreeInfo] = []
    public var graph: [GraphCommit] = []
    public var allBranches = false
    public var selectedCommit: String?
    public var hasMoreHistory = true
    public var isLoading = false
    public var error: String?
    public var branchName = ""
    public var startPoint = ""
    public var worktreePath = ""
    public var selectedConflict: String?
    public var conflictDocument: ConflictDocument?
    public var resolution = ""
    public var conflictChangedExternally = false
    public var isLoadingConflict = false
    private var generation = 0
    private var conflictGeneration = 0
    private var conflictDrafts: [String: (ConflictDocument, String)] = [:]

    public init() {}

    public func refresh(using vm: RepoViewModel) async {
        generation += 1
        let request = generation
        let service = RepositoryService(gitPath: vm.client.gitPath)
        let all = allBranches
        let requestedCount = max(100, graph.count)
        isLoading = true
        defer { if request == generation { isLoading = false } }
        do {
            async let branchList = service.branches(in: vm.repo.path)
            async let worktreeList = service.worktrees(in: vm.repo.path)
            async let history = historyWindow(service: service, repo: vm.repo.path, all: all, count: requestedCount)
            let result = try await (branchList, worktreeList, history)
            guard request == generation, !Task.isCancelled else { return }
            branches = result.0
            worktrees = result.1
            var seen = Set<String>()
            graph = result.2.filter { seen.insert($0.id).inserted }
            hasMoreHistory = graph.count >= 100 && graph.count % 100 == 0
            error = nil
        } catch {
            guard request == generation, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
        if let document = conflictDocument {
            let current = try? await service.conflict(path: document.path, in: vm.repo.path)
            guard request == generation else { return }
            conflictChangedExternally = current != document
        }
    }

    private func historyWindow(service: RepositoryService, repo: URL, all: Bool, count: Int) async throws -> [GraphCommit] {
        var result: [GraphCommit] = []
        repeat {
            try Task.checkCancellation()
            let page = try await service.graph(in: repo, allBranches: all, skip: result.count, limit: 100)
            result += page
            if page.count < 100 { break }
        } while result.count < count
        return result
    }

    public func loadMore(using vm: RepoViewModel) async {
        guard !isLoading, hasMoreHistory else { return }
        generation += 1
        let request = generation
        isLoading = true
        defer { if request == generation { isLoading = false } }
        do {
            let service = RepositoryService(gitPath: vm.client.gitPath)
            let first = try await service.graph(in: vm.repo.path, allBranches: allBranches, limit: 1)
            guard request == generation, !Task.isCancelled else { return }
            if first.first?.id != graph.first?.id {
                await refresh(using: vm)
                return
            }
            let page = try await service.graph(in: vm.repo.path, allBranches: allBranches, skip: graph.count)
            guard request == generation, !Task.isCancelled else { return }
            // External history rewrites cannot insert duplicate identities in the list.
            let existing = Set(graph.map(\.id))
            graph += page.filter { !existing.contains($0.id) }
            hasMoreHistory = page.count == 100
            error = nil
        } catch {
            if request == generation, !Task.isCancelled { self.error = error.localizedDescription }
        }
    }

    public func loadConflict(_ path: String, using vm: RepoViewModel, reload: Bool = false) async {
        if let document = conflictDocument { conflictDrafts[document.path] = (document, resolution) }
        conflictGeneration += 1
        let request = conflictGeneration
        selectedConflict = path
        conflictDocument = nil
        isLoadingConflict = true
        defer { if request == conflictGeneration { isLoadingConflict = false } }
        do {
            let document = try await RepositoryService(gitPath: vm.client.gitPath).conflict(path: path, in: vm.repo.path)
            guard request == conflictGeneration, !Task.isCancelled else { return }
            if !reload, let saved = conflictDrafts[path] {
                conflictDocument = saved.0
                resolution = saved.1
                conflictChangedExternally = saved.0 != document
            } else {
                conflictDocument = document
                resolution = document.workingText ?? ""
                conflictChangedExternally = false
            }
            error = nil
        } catch {
            guard request == conflictGeneration else { return }
            conflictDocument = nil
            self.error = error.localizedDescription
        }
    }

    public func saveResolution(using vm: RepoViewModel) async {
        guard let document = conflictDocument, document.path == selectedConflict, !isLoadingConflict else { return }
        let submitted = resolution
        let result = await vm.performAction(allowInProgress: true) {
            try await RepositoryService(gitPath: vm.client.gitPath).saveConflict(document, resolvedText: submitted, in: vm.repo.path)
        }
        if result == .succeeded {
            // Refresh the disk snapshot without destroying edits typed during the save.
            let updated = try? await RepositoryService(gitPath: vm.client.gitPath).conflict(path: document.path, in: vm.repo.path)
            if selectedConflict == document.path {
                conflictDocument = updated
                conflictChangedExternally = false
            }
        }
    }

    public func markResolved(using vm: RepoViewModel) async {
        guard let document = conflictDocument, document.path == selectedConflict, !isLoadingConflict,
              resolution == document.workingText else { return }
        let result = await vm.performAction(allowInProgress: true) {
            try await RepositoryService(gitPath: vm.client.gitPath).markConflictResolved(document, in: vm.repo.path)
        }
        if result == .succeeded, selectedConflict == document.path {
            conflictDrafts.removeValue(forKey: document.path)
            conflictDocument = nil
            selectedConflict = nil
            resolution = ""
        }
    }
}

public struct GraphLaneRow: Equatable, Sendable {
    public let column: Int
    public let width: Int
    public let incomingColumns: [Int]
    public let edges: [GraphLaneEdge]

    public static func layout(_ commits: [GraphCommit]) -> [GraphLaneRow] {
        var lanes: [String] = []
        return commits.map { node in
            if !lanes.contains(node.id) { lanes.append(node.id) }
            let before = lanes
            let column = lanes.firstIndex(of: node.id)!
            lanes.remove(at: column)
            for (offset, parent) in node.parents.enumerated() where !lanes.contains(parent) {
                lanes.insert(parent, at: min(column + offset, lanes.count))
            }
            var edges = before.enumerated().compactMap { index, oid -> GraphLaneEdge? in
                guard oid != node.id, let target = lanes.firstIndex(of: oid) else { return nil }
                return GraphLaneEdge(from: index, to: target, fromNode: false)
            }
            edges += node.parents.compactMap { parent in
                lanes.firstIndex(of: parent).map { GraphLaneEdge(from: column, to: $0, fromNode: true) }
            }
            return GraphLaneRow(column: column, width: max(before.count, lanes.count),
                                incomingColumns: Array(before.indices), edges: edges)
        }
    }
}

public struct GraphLaneEdge: Equatable, Sendable {
    public let from: Int
    public let to: Int
    public let fromNode: Bool
}
