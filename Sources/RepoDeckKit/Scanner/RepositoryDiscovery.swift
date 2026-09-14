import Foundation

/// Filesystem roots identify repositories; Git's worktree registry identifies
/// their checkouts, including siblings outside a tracked folder. Bare stores
/// are discovery seeds only and never appear as editable working directories.
public enum RepositoryDiscovery {
    private struct Seed: Sendable {
        let path: URL
        let hasWorktreeMarker: Bool
    }

    public static func scan(roots: [URL], gitPath: String = GitDefaults.gitPath) async -> [Repo] {
        let scanning = Task.detached(priority: .utility) {
            var seeds: [Seed] = []
            for root in roots { findSeeds(root, depth: 0, into: &seeds) }
            return seeds
        }
        let seeds = await withTaskCancellationHandler { await scanning.value } onCancel: { scanning.cancel() }
        var results: [String: Repo] = [:]
        var visited = Set<String>()
        for seed in seeds {
            guard !Task.isCancelled else { break }
            let path = seed.path.resolvingSymlinksInPath().standardizedFileURL
            guard visited.insert(path.path).inserted else { continue }
            // Retain malformed ordinary checkouts so their existing status
            // diagnostic remains visible. Bare metadata has no working files.
            if seed.hasWorktreeMarker { results[path.path] = Repo(path: path) }
            guard let result = try? await ProcessRunner.run(
                gitPath, arguments: ["-C", path.path, "worktree", "list", "--porcelain", "-z"],
                maxOutputBytes: 1024 * 1024, priority: .background, timeout: .seconds(10)
            ), result.exitCode == 0, !result.outputTruncated, !result.timedOut else { continue }
            for checkout in worktreePaths(from: result.stdout) {
                let canonical = checkout.resolvingSymlinksInPath().standardizedFileURL
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: canonical.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
                results[canonical.path] = Repo(path: canonical)
            }
        }
        return results.values.sorted {
            let order = $0.name.localizedCaseInsensitiveCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    private static func findSeeds(_ directory: URL, depth: Int, into seeds: inout [Seed]) {
        guard !Task.isCancelled else { return }
        let fm = FileManager.default
        if fm.fileExists(atPath: directory.appendingPathComponent(".git").path) {
            seeds.append(Seed(path: directory, hasWorktreeMarker: true))
            return
        }
        var objectsIsDirectory: ObjCBool = false
        var refsIsDirectory: ObjCBool = false
        if fm.fileExists(atPath: directory.appendingPathComponent("HEAD").path),
           fm.fileExists(atPath: directory.appendingPathComponent("objects").path, isDirectory: &objectsIsDirectory), objectsIsDirectory.boolValue,
           fm.fileExists(atPath: directory.appendingPathComponent("refs").path, isDirectory: &refsIsDirectory), refsIsDirectory.boolValue {
            seeds.append(Seed(path: directory, hasWorktreeMarker: false))
            return
        }
        guard depth < 8, let children = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ) else { return }
        for child in children {
            let name = child.lastPathComponent
            guard !name.hasPrefix("."), !RepoScanner.prunedNames.contains(name),
                  let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true else { continue }
            findSeeds(child, depth: depth + 1, into: &seeds)
        }
    }

    /// -z preserves literal newlines and other unusual characters in paths.
    /// A blank NUL token ends a record; incomplete records are not accepted.
    public static func worktreePaths(from data: Data) -> [URL] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var paths: [URL] = []
        var path: String?
        var excluded = false
        for field in text.split(separator: "\0", omittingEmptySubsequences: false) {
            if field.isEmpty {
                if let path, path.hasPrefix("/"), !excluded { paths.append(URL(fileURLWithPath: path)) }
                path = nil
                excluded = false
            } else if field.hasPrefix("worktree ") { path = String(field.dropFirst(9)) }
            else if field == "bare" || field == "prunable" || field.hasPrefix("prunable ") { excluded = true }
        }
        return paths
    }
}
