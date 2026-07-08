import Foundation

/// Synchronously, recursively discovers git repositories under a root folder.
///
/// Callers running on the main actor should wrap `scan(root:)` in `Task.detached`
/// since it performs blocking filesystem I/O.
public struct RepoScanner: Sendable {
    public var maxDepth: Int = 8

    /// Directory names that are never descended into, regardless of depth.
    public static let prunedNames: Set<String> = [
        "node_modules", "Pods", "DerivedData", "Carthage", "vendor", "__pycache__", "target",
    ]

    public init(maxDepth: Int = 8) {
        self.maxDepth = maxDepth
    }

    /// Recursively scans `root`, returning discovered repos sorted by name (case-insensitive).
    public func scan(root: URL) -> [Repo] {
        var results: [Repo] = []
        scan(directory: root, depth: 0, into: &results)
        return results.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func scan(directory: URL, depth: Int, into results: inout [Repo]) {
        // Rule 1: a `.git` entry (directory or file — a file marks a linked worktree)
        // means this directory is a repo; stop descending into it.
        if isGitRepo(directory) {
            results.append(Repo(path: directory))
            return
        }

        // Rule 2 (depth clause): do not descend further once maxDepth would be exceeded.
        guard depth < maxDepth else { return }

        // Rule 3: list children without .skipsHiddenFiles so `.git` itself is never hidden
        // from the listing; hidden-directory filtering happens explicitly below.
        let children: [URL]
        do {
            children = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            )
        } catch {
            // Ignore per-directory read errors (e.g. permissions); continue with siblings.
            return
        }

        for child in children {
            let name = child.lastPathComponent

            // Rule 2: skip hidden directories and known pruned directory names.
            if name.hasPrefix(".") { continue }
            if Self.prunedNames.contains(name) { continue }

            guard let resourceValues = try? child.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            ) else {
                continue
            }

            // Rule 2: never follow symlinked directories (cycle guard).
            if resourceValues.isSymbolicLink == true { continue }
            guard resourceValues.isDirectory == true else { continue }

            scan(directory: child, depth: depth + 1, into: &results)
        }
    }

    private func isGitRepo(_ directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path)
    }
}
