import Foundation

/// Local Git workflows. The caller holds RepositoryMutationCoordinator for
/// mutations; checks here also reject stale UI state and unsafe Git operations.
public struct RepositoryService: Sendable {
    public let gitPath: String
    private var client: GitClient { GitClient(gitPath: gitPath) }
    private static let outputLimit = 10_000_000

    public init(gitPath: String = GitDefaults.gitPath) { self.gitPath = gitPath }

    public func branches(in repo: URL) async throws -> [BranchInfo] {
        let format = "%(refname)%00%(objectname)%00%(HEAD)%00%(upstream:short)%00%(worktreepath)%00%(symref)%00"
        let result = try await run(["for-each-ref", "--sort=refname", "--format=" + format, "refs/heads", "refs/remotes"], in: repo)
        let fields = try utf8(result.stdout).components(separatedBy: "\0")
        var branches: [BranchInfo] = []
        for offset in stride(from: 0, to: max(0, fields.count - 6), by: 6) {
            let fullRef = fields[offset].trimmingCharacters(in: .newlines)
            guard fields[offset + 5].isEmpty else { continue } // symbolic origin/HEAD
            let remote = fullRef.hasPrefix("refs/remotes/")
            let prefix = remote ? "refs/remotes/" : "refs/heads/"
            guard fullRef.hasPrefix(prefix) else { throw failure("Unable to read the branch list safely.") }
            branches.append(BranchInfo(name: String(fullRef.dropFirst(prefix.count)), fullRef: fullRef,
                                       oid: fields[offset + 1], isCurrent: fields[offset + 2] == "*", isRemote: remote,
                                       upstream: nonempty(fields[offset + 3]), worktreePath: nonempty(fields[offset + 4])))
        }
        return branches
    }

    public func createBranch(name: String, startPoint: String? = nil, switchTo: Bool = true, in repo: URL) async throws {
        try await requireNormal(in: repo)
        try await validateBranch(name, in: repo)
        let start: String?
        if let startPoint { start = try await commitOID(startPoint, in: repo) } else { start = nil }
        var arguments = switchTo ? ["switch", "-c", name] : ["branch", "--", name]
        if let start { arguments.append(start) }
        _ = try await run(arguments, in: repo)
    }

    public func switchBranch(_ name: String, expected: BranchInfo? = nil, in repo: URL) async throws {
        try await requireNormal(in: repo)
        try await validateBranch(name, in: repo)
        try await validateSnapshot(expected, for: name, in: repo)
        _ = try await run(["switch", "--", name], in: repo)
    }

    public func renameBranch(_ name: String, to newName: String, expected: BranchInfo? = nil, in repo: URL) async throws {
        try await requireNormal(in: repo)
        try await validateBranch(name, in: repo)
        try await validateBranch(newName, in: repo)
        let checkedOut = try await worktrees(in: repo).filter { $0.branch == name }
        let root = try await RepositoryContext.resolve(in: repo, gitPath: gitPath).worktreeRoot
        guard checkedOut.allSatisfy({ $0.path.resolvingSymlinksInPath().standardizedFileURL == root }) else {
            throw failure("That branch is checked out in another worktree.")
        }
        try await validateSnapshot(expected, for: name, in: repo)
        _ = try await run(["branch", "-m", "--", name, newName], in: repo)
    }

    public func deleteBranch(_ name: String, expected: BranchInfo? = nil, in repo: URL) async throws {
        try await requireNormal(in: repo)
        try await validateBranch(name, in: repo)
        guard try await worktrees(in: repo).allSatisfy({ $0.branch != name }) else {
            throw failure("Switch away from that branch in every worktree before deleting it.")
        }
        try await validateSnapshot(expected, for: name, in: repo)
        _ = try await run(["branch", "-d", "--", name], in: repo)
    }

    public func setUpstream(_ upstream: String?, for branch: String, expected: BranchInfo? = nil, in repo: URL) async throws {
        try await requireNormal(in: repo)
        try await validateBranch(branch, in: repo)
        if let upstream {
            _ = try await commitOID(upstream, in: repo)
            try await validateSnapshot(expected, for: branch, in: repo)
            _ = try await run(["branch", "--set-upstream-to=" + upstream, "--", branch], in: repo)
        } else {
            try await validateSnapshot(expected, for: branch, in: repo)
            _ = try await run(["branch", "--unset-upstream", "--", branch], in: repo)
        }
    }

    public func merge(_ branch: String, expected: BranchInfo? = nil, in repo: URL) async throws {
        try await requireCleanNormal(in: repo)
        let oid = try await commitOID(branch, in: repo)
        try await validateSnapshot(expected, for: branch, resolvedOID: oid, in: repo)
        _ = try await run(["-c", "merge.autoStash=false", "merge", "--no-edit", "--", oid], in: repo)
    }

    public func rebase(onto branch: String, expected: BranchInfo? = nil, in repo: URL) async throws {
        try await requireCleanNormal(in: repo)
        let oid = try await commitOID(branch, in: repo)
        try await validateSnapshot(expected, for: branch, resolvedOID: oid, in: repo)
        _ = try await run(["-c", "rebase.autoStash=false", "rebase", "--", oid], in: repo)
    }

    public func worktrees(in repo: URL) async throws -> [WorktreeInfo] {
        let result = try await run(["worktree", "list", "--porcelain", "-z"], in: repo)
        let records = try utf8(result.stdout).components(separatedBy: "\0\0")
        var worktrees: [WorktreeInfo] = []
        for record in records where !record.isEmpty {
            let fields = record.components(separatedBy: "\0")
            guard let path = fields.first, path.hasPrefix("worktree ") else {
                throw failure("Unable to read the worktree list safely.")
            }
            func value(_ prefix: String) -> String? { fields.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) } }
            let ref = value("branch ")
            worktrees.append(WorktreeInfo(path: URL(fileURLWithPath: String(path.dropFirst(9))),
                                          branch: ref.map { $0.hasPrefix("refs/heads/") ? String($0.dropFirst(11)) : $0 },
                                          oid: value("HEAD "), isMain: worktrees.isEmpty, isBare: fields.contains("bare"),
                                          isLocked: fields.contains { $0 == "locked" || $0.hasPrefix("locked ") },
                                          isPrunable: fields.contains { $0 == "prunable" || $0.hasPrefix("prunable ") }))
        }
        return worktrees
    }

    public func createWorktree(at path: URL, branch: String, createBranch: Bool = false, in repo: URL) async throws {
        try await requireNormal(in: repo)
        try await validateBranch(branch, in: repo)
        guard path.isFileURL, !FileManager.default.fileExists(atPath: path.path) else {
            throw failure("Choose a new directory for this worktree.")
        }
        var arguments = ["worktree", "add"]
        if createBranch { arguments += ["-b", branch] }
        arguments += ["--", path.path]
        if !createBranch { arguments.append(branch) }
        _ = try await run(arguments, in: repo)
    }

    public func removeWorktree(_ worktree: WorktreeInfo, in repo: URL) async throws {
        try await requireNormal(in: repo)
        let context = try await RepositoryContext.resolve(in: repo, gitPath: gitPath)
        guard let current = try await worktrees(in: repo).first(where: { $0.id == worktree.id }),
              !current.isMain, !current.isBare, !current.isLocked, !current.isPrunable,
              current.path.resolvingSymlinksInPath().standardizedFileURL != context.worktreeRoot else {
            throw failure("This worktree is current, locked, missing, or is the main worktree. It cannot be removed here.")
        }
        guard current == worktree else {
            throw failure("This worktree changed since it was selected. Refresh and review its branch and commit before removing it.")
        }
        // Native worktree removal allows ignored files to be deleted. Include
        // every path outside the index, without applying ignore exclusions.
        let extraFiles = try await run(["ls-files", "--others", "-z"], in: current.path)
        guard extraFiles.stdout.isEmpty else {
            throw failure("This worktree contains untracked or ignored files. Back up or remove those files before removing the worktree.")
        }
        try await requireCleanNormal(in: current.path)
        guard try await worktrees(in: repo).first(where: { $0.id == worktree.id }) == worktree else {
            throw failure("This worktree changed while checking it. Refresh before removing it.")
        }
        _ = try await run(["worktree", "remove", "--", current.path.path], in: repo)
    }

    public func graph(in repo: URL, allBranches: Bool = false, skip: Int = 0, limit: Int = 100) async throws -> [GraphCommit] {
        guard skip >= 0, (1...1000).contains(limit) else { throw failure("Invalid history page.") }
        let head = try await run(["rev-parse", "--verify", "--quiet", "HEAD"], in: repo, tolerated: [1])
        if head.exitCode == 1, !allBranches { return [] }
        let format = "%H%x00%P%x00%h%x00%s%x00%an%x00%aI%x00%D%x00"
        var arguments = ["log", "--no-color", "--no-show-signature", "--encoding=UTF-8", "--topo-order", "--skip=\(skip)", "-n", String(limit), "--pretty=format:" + format]
        if allBranches { arguments += ["--branches", "--remotes", "--tags"] }
        let result = try await run(arguments, in: repo)
        if result.stdout.isEmpty { return [] }
        let fields = try utf8(result.stdout).components(separatedBy: "\0")
        let formatter = ISO8601DateFormatter()
        var commits: [GraphCommit] = []
        for offset in stride(from: 0, to: max(0, fields.count - 7), by: 7) {
            guard let date = formatter.date(from: fields[offset + 5]) else { throw failure("Unable to read commit dates.") }
            let oid = fields[offset].trimmingCharacters(in: .newlines)
            let refs = fields[offset + 6].isEmpty ? [] : fields[offset + 6].components(separatedBy: ", ")
            let commit = Commit(hash: oid, shortHash: fields[offset + 2], subject: fields[offset + 3],
                                author: fields[offset + 4], date: date, refs: refs)
            commits.append(GraphCommit(commit: commit, parents: fields[offset + 1].split(separator: " ").map(String.init)))
        }
        return commits
    }

    public func conflict(path: String, in repo: URL) async throws -> ConflictDocument {
        let context = try await RepositoryContext.resolve(in: repo, gitPath: gitPath)
        let file = try conflictURL(path, root: context.worktreeRoot)
        let entries = try await run(["--literal-pathspecs", "ls-files", "--unmerged", "-z", "--", path], in: context.worktreeRoot).stdout
        guard !entries.isEmpty else { throw failure("This file is no longer conflicted. Refresh the repository.") }
        var blobs: [Int: String] = [:]
        var stages: Set<Int> = []
        var modes: Set<String> = []
        var reason: String?
        for entry in entries.split(separator: 0) {
            guard let tab = entry.firstIndex(of: 9) else { throw failure("Unable to read conflict stages.") }
            let fields = try utf8(Data(entry[..<tab])).split(separator: " ")
            guard fields.count == 3, let stage = Int(fields[2]) else { throw failure("Unable to read conflict stages.") }
            stages.insert(stage)
            modes.insert(String(fields[0]))
            if fields[0] != "100644", fields[0] != "100755" { reason = "Symlink and submodule conflicts must be resolved in another tool." }
            if fields[0] == "160000" { continue }
            let blob = try await run(["cat-file", "blob", String(fields[1])], in: repo).stdout
            if BinarySniffer.isLikelyBinary(blob) || String(data: blob, encoding: .utf8) == nil {
                reason = "Binary or non-UTF-8 conflicts must be resolved in another tool."
            } else { blobs[stage] = String(data: blob, encoding: .utf8) }
        }
        if !stages.isSuperset(of: [2, 3]) {
            reason = "Deletion and complex rename conflicts must be resolved in another tool."
        } else if modes.count != 1 {
            reason = "This conflict changes file modes. Resolve it in another tool to preserve the intended mode."
        }
        let status = try await client.status(in: context.worktreeRoot)
        if status.didHitLimit || status.changes.contains(where: {
            $0.originalPath != nil && ($0.path == path || $0.originalPath == path)
        }) {
            reason = "This rename conflict cannot be edited safely here. Resolve it in another tool."
        }
        let attributes = try await run(["check-attr", "-z", "filter", "working-tree-encoding", "ident", "--", path], in: context.worktreeRoot)
        let attributeFields = try utf8(attributes.stdout).components(separatedBy: "\0")
        for offset in stride(from: 0, to: max(0, attributeFields.count - 3), by: 3) {
            let value = attributeFields[offset + 2]
            if value != "unspecified", value != "unset" {
                reason = "This file uses Git content filters or encoding attributes. Resolve it in another tool."
            }
        }
        var workingData: Data?
        var mode: UInt16?
        if let attributes = try? FileManager.default.attributesOfItem(atPath: file.path) {
            if attributes[.type] as? FileAttributeType != .typeRegular {
                reason = "Only regular text files can be edited here."
            } else if (attributes[.size] as? NSNumber)?.intValue ?? 0 > Self.outputLimit {
                reason = "This conflict is too large to edit here."
            } else {
                workingData = try Data(contentsOf: file)
                mode = (attributes[.posixPermissions] as? NSNumber)?.uint16Value
                if let workingData, BinarySniffer.isLikelyBinary(workingData) || String(data: workingData, encoding: .utf8) == nil {
                    reason = "Binary or non-UTF-8 conflicts must be resolved in another tool."
                }
            }
        } else { reason = "The working file is missing. Resolve this deletion in another tool, then refresh." }
        return ConflictDocument(path: path, base: blobs[1], current: blobs[2], incoming: blobs[3],
                                workingText: workingData.flatMap { String(data: $0, encoding: .utf8) }, unavailableReason: reason,
                                repositoryPath: context.worktreeRoot.path, headOID: try await client.headOID(in: repo),
                                indexEntries: entries, workingData: workingData, workingMode: mode)
    }

    /// Saving and marking resolved are deliberately separate user actions.
    public func saveConflict(_ document: ConflictDocument, resolvedText: String, in repo: URL) async throws {
        try await validateConflictSnapshot(document, in: repo)
        guard !resolvedText.utf8.contains(0), resolvedText.utf8.count <= Self.outputLimit else {
            throw failure("Resolution must be a text file under 10 MB.")
        }
        let file = try conflictURL(document.path, root: URL(fileURLWithPath: document.repositoryPath))
        try Data(resolvedText.utf8).write(to: file, options: .atomic)
        if let mode = document.workingMode { try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path) }
    }

    public func markConflictResolved(_ document: ConflictDocument, in repo: URL) async throws {
        try await validateConflictSnapshot(document, in: repo)
        if document.workingText?.components(separatedBy: "\n").contains(where: { $0.hasPrefix("<<<<<<< ") || $0.hasPrefix(">>>>>>> ") }) == true {
            throw failure("Conflict markers remain in this file. Save the resolution before marking it resolved.")
        }
        try await client.stage([document.path], in: repo)
    }

    public func continueOperation(in repo: URL) async throws {
        let context = try await RepositoryContext.resolve(in: repo, gitPath: gitPath)
        let state = RepositoryOperationState.read(in: context)
        let status = try await client.status(in: repo)
        guard !status.didHitLimit, !status.changes.contains(where: { $0.area == .unmerged }) else {
            throw failure("Resolve and stage every conflicted file before continuing.")
        }
        _ = try await run([try operationCommand(state), "--continue"], in: repo,
                          environment: ["GIT_EDITOR": "true", "GIT_SEQUENCE_EDITOR": "true"])
    }

    public func abortOperation(in repo: URL) async throws {
        let context = try await RepositoryContext.resolve(in: repo, gitPath: gitPath)
        _ = try await run([try operationCommand(RepositoryOperationState.read(in: context)), "--abort"], in: repo)
    }

    private func validateConflictSnapshot(_ document: ConflictDocument, in repo: URL) async throws {
        guard document.canEdit else { throw failure(document.unavailableReason ?? "This conflict cannot be edited here.") }
        let current = try await conflict(path: document.path, in: repo)
        guard current == document else {
            throw failure("The conflict changed on disk. Reload it before saving or marking it resolved.")
        }
    }

    private func conflictURL(_ path: String, root: URL) throws -> URL {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.utf8.contains(0), !path.split(separator: "/").contains("..") else {
            throw failure("Invalid conflict path.")
        }
        let file = root.appendingPathComponent(path).standardizedFileURL
        let parent = file.deletingLastPathComponent().resolvingSymlinksInPath().path
        guard parent == root.path || parent.hasPrefix(root.path + "/") else { throw failure("Conflict path is outside this worktree.") }
        return file
    }

    private func requireNormal(in repo: URL) async throws {
        let context = try await RepositoryContext.resolve(in: repo, gitPath: gitPath)
        let state = RepositoryOperationState.read(in: context)
        guard state == .normal else { throw failure("\(state.label). Continue or abort that operation first.") }
    }

    private func requireCleanNormal(in repo: URL) async throws {
        try await requireNormal(in: repo)
        let status = try await client.status(in: repo)
        guard !status.didHitLimit, status.changes.isEmpty else {
            throw failure("Commit or stash local changes before this operation.")
        }
    }

    private func operationCommand(_ state: RepositoryOperationState) throws -> String {
        switch state {
        case .merge: return "merge"
        case .rebase: return "rebase"
        case .cherryPick: return "cherry-pick"
        case .revert: return "revert"
        case .normal: throw failure("No Git operation is in progress.")
        case .unsupported: throw failure("Continue or abort this Git operation from your terminal.")
        }
    }

    private func validateSnapshot(_ expected: BranchInfo?, for name: String, resolvedOID: String? = nil, in repo: URL) async throws {
        guard let expected else { return }
        guard name == expected.name || name == expected.fullRef,
              resolvedOID == nil || resolvedOID == expected.oid,
              try await branches(in: repo).first(where: { $0.id == expected.id }) == expected else {
            throw failure("This branch changed since it was selected. Refresh and review its commit and tracking state before continuing.")
        }
    }

    private func validateBranch(_ name: String, in repo: URL) async throws {
        guard !name.isEmpty, !name.hasPrefix("-"), !name.utf8.contains(0) else { throw failure("Invalid branch name.") }
        _ = try await run(["check-ref-format", "refs/heads/" + name], in: repo)
    }

    private func commitOID(_ ref: String, in repo: URL) async throws -> String {
        guard !ref.isEmpty, !ref.hasPrefix("-"), !ref.utf8.contains(0) else { throw failure("Invalid revision.") }
        let result = try await run(["rev-parse", "--verify", "--end-of-options", ref + "^{commit}"], in: repo)
        return try utf8(result.stdout).trimmingCharacters(in: .newlines)
    }

    private func run(_ arguments: [String], in repo: URL, tolerated: Set<Int32> = [], environment: [String: String] = [:]) async throws -> ProcessResult {
        let result = try await ProcessRunner.run(gitPath, arguments: ["-C", repo.path] + arguments,
                                                 environment: environment, maxOutputBytes: Self.outputLimit)
        guard !result.outputTruncated else { throw failure("Git output exceeds the 10 MB limit. Use a smaller view or an external tool.") }
        guard result.exitCode == 0 || tolerated.contains(result.exitCode) else {
            throw GitError(command: "git " + arguments.joined(separator: " "), exitCode: result.exitCode, stderr: result.stderr)
        }
        return result
    }

    private func utf8(_ data: Data) throws -> String {
        guard let value = String(data: data, encoding: .utf8) else { throw failure("Git returned text outside UTF-8. Use an external tool for this operation.") }
        return value
    }

    private func nonempty(_ value: String) -> String? { value.isEmpty ? nil : value }
    private func failure(_ message: String) -> GitError { GitError(command: "git", exitCode: -1, stderr: message) }
}
