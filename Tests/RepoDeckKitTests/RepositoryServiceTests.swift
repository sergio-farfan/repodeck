import Foundation
import Testing
@testable import RepoDeckKit

@Suite struct RepositoryServiceTests {
    @discardableResult
    private func git(_ arguments: [String], in repo: URL) async throws -> ProcessResult {
        let result = try await TestGitRepository.run(arguments: ["-C", repo.path] + arguments)
        try #require(result.exitCode == 0, "git \(arguments) failed: \(result.stderr)")
        return result
    }

    private func withRepo(_ body: (URL, RepositoryService) async throws -> Void) async throws {
        try await TestGitRepository.withRepository { repo, _ in
            try await body(repo, RepositoryService())
        }
    }

    private func commit(_ text: String, file: String = "base.txt", in repo: URL) async throws {
        try Data(text.utf8).write(to: repo.appendingPathComponent(file))
        try await GitClient().stageAll(in: repo)
        try await GitClient().commit(message: text.trimmingCharacters(in: .newlines), in: repo)
    }

    @Test func branchLifecycleAndSafeDeletion() async throws {
        try await withRepo { repo, service in
            #expect(try await service.graph(in: repo).isEmpty)
            #expect(try await service.graph(in: repo, allBranches: true).isEmpty)
            try await commit("base\n", in: repo)
            try await service.createBranch(name: "feature", switchTo: false, in: repo)
            var branches = try await service.branches(in: repo)
            #expect(branches.map(\.name) == ["feature", "main"])
            #expect(branches.first { $0.isCurrent }?.name == "main")
            let feature = try #require(branches.first { $0.name == "feature" })
            try await service.switchBranch("feature", expected: feature, in: repo)
            let checkedOutFeature = try #require(try await service.branches(in: repo).first { $0.name == "feature" })
            try await service.renameBranch("feature", to: "renamed", expected: checkedOutFeature, in: repo)
            branches = try await service.branches(in: repo)
            #expect(branches.first { $0.isCurrent }?.name == "renamed")
            await #expect(throws: GitError.self) { try await service.deleteBranch("renamed", in: repo) }
            try await commit("feature\n", file: "feature.txt", in: repo)
            try await service.switchBranch("main", in: repo)
            await #expect(throws: GitError.self) { try await service.deleteBranch("renamed", in: repo) }
            let renamed = try #require(try await service.branches(in: repo).first { $0.name == "renamed" })
            try await service.merge("renamed", expected: renamed, in: repo)
            try await service.deleteBranch("renamed", expected: renamed, in: repo)
            #expect(try await service.branches(in: repo).map(\.name) == ["main"])
            await #expect(throws: GitError.self) { try await service.createBranch(name: "--bad", in: repo) }
        }
    }

    @Test(arguments: ["switch", "rename", "delete", "tracking", "removeTracking", "merge", "rebase"])
    func staleBranchActionsPreserveRepository(_ action: String) async throws {
        try await withRepo { repo, service in
            try await commit("base\n", in: repo)
            try await service.createBranch(name: "feature", switchTo: false, in: repo)
            try await service.setUpstream("main", for: "feature", in: repo)
            let selected = try #require(try await service.branches(in: repo).first { $0.name == "feature" })
            try await commit("new main\n", in: repo)
            // Simulate another Git client moving the selected target while the
            // confirmation remains open; our current branch has not switched.
            try await git(["update-ref", "refs/heads/feature", "HEAD"], in: repo)
            let beforeBranches = try await service.branches(in: repo)
            let beforeIndex = try await git(["ls-files", "--stage", "-z"], in: repo).stdout
            let beforeBytes = try Data(contentsOf: repo.appendingPathComponent("base.txt"))
            do {
                switch action {
                case "switch": try await service.switchBranch(selected.name, expected: selected, in: repo)
                case "rename": try await service.renameBranch(selected.name, to: "renamed", expected: selected, in: repo)
                case "delete": try await service.deleteBranch(selected.name, expected: selected, in: repo)
                case "tracking": try await service.setUpstream("main", for: selected.name, expected: selected, in: repo)
                case "removeTracking": try await service.setUpstream(nil, for: selected.name, expected: selected, in: repo)
                case "merge": try await service.merge(selected.fullRef, expected: selected, in: repo)
                default: try await service.rebase(onto: selected.fullRef, expected: selected, in: repo)
                }
                Issue.record("A stale branch confirmation must be rejected")
            } catch let error as GitError {
                #expect(error.stderr.contains("changed since it was selected"))
            }
            #expect(try await service.branches(in: repo) == beforeBranches)
            #expect(try await git(["ls-files", "--stage", "-z"], in: repo).stdout == beforeIndex)
            #expect(try Data(contentsOf: repo.appendingPathComponent("base.txt")) == beforeBytes)
        }
    }

    @Test(arguments: [false, true])
    func worktreeRemovalRejectsChangedBranchOrDetachedCommit(detached: Bool) async throws {
        try await withRepo { repo, service in
            try await commit("base\n", in: repo)
            let path = repo.deletingLastPathComponent().appendingPathComponent("changed target")
            try await service.createWorktree(at: path, branch: "feature", createBranch: true, in: repo)
            let selected = try #require(try await service.worktrees(in: repo).first { !$0.isMain })
            if detached {
                try await git(["switch", "--detach"], in: path)
                try await commit("detached content\n", in: path)
            } else {
                try await git(["switch", "-c", "another"], in: path)
            }
            let before = try await service.worktrees(in: repo)
            let bytes = try Data(contentsOf: path.appendingPathComponent("base.txt"))
            do {
                try await service.removeWorktree(selected, in: repo)
                Issue.record("A stale worktree confirmation must be rejected")
            } catch let error as GitError {
                #expect(error.stderr.contains("changed since it was selected"))
            }
            #expect(try await service.worktrees(in: repo) == before)
            #expect(try Data(contentsOf: path.appendingPathComponent("base.txt")) == bytes)
        }
    }

    @Test func graphPreservesMergeParentsAndPaginatesWithoutDuplicateCommits() async throws {
        try await withRepo { repo, service in
            try await commit("base\n", in: repo)
            try await service.createBranch(name: "feature", in: repo)
            try await commit("feature\n", file: "feature.txt", in: repo)
            try await service.switchBranch("main", in: repo)
            try await commit("main\n", file: "main.txt", in: repo)
            try await service.merge("feature", in: repo)
            let all = try await service.graph(in: repo, allBranches: true)
            #expect(all.count == 4)
            #expect(all.first?.parents.count == 2)
            let first = try await service.graph(in: repo, limit: 2)
            let second = try await service.graph(in: repo, skip: 2, limit: 2)
            #expect(first.map(\.hash) + second.map(\.hash) == all.map(\.hash))
            #expect(Set(all.map(\.hash)).count == 4)
        }
    }

    @Test func worktreeRemovalRechecksLocksAndDirtyState() async throws {
        try await withRepo { repo, service in
            try await commit("base\n", in: repo)
            let path = repo.deletingLastPathComponent().appendingPathComponent("linked worktree")
            try await service.createWorktree(at: path, branch: "feature", createBranch: true, in: repo)
            let trees = try await service.worktrees(in: repo)
            #expect(trees.count == 2)
            #expect(trees.first?.isMain == true)
            let linked = try #require(trees.first { !$0.isMain })
            #expect(linked.branch == "feature")
            try await git(["worktree", "lock", path.path], in: repo)
            await #expect(throws: GitError.self) { try await service.removeWorktree(linked, in: repo) }
            try await git(["worktree", "unlock", path.path], in: repo)
            try Data("dirty\n".utf8).write(to: path.appendingPathComponent("new.txt"))
            await #expect(throws: GitError.self) { try await service.removeWorktree(linked, in: repo) }
            await #expect(throws: GitError.self) { try await service.deleteBranch("feature", in: repo) }
            try FileManager.default.removeItem(at: path.appendingPathComponent("new.txt"))
            try await service.removeWorktree(linked, in: repo)
            #expect(!FileManager.default.fileExists(atPath: path.path))
            #expect(try await service.worktrees(in: repo).count == 1)
        }
    }

    @Test func worktreeRemovalKeepsIgnoredFilesEvenWhenStatusIsClean() async throws {
        try await withRepo { repo, service in
            try await commit(".env\nbuild/\n", file: ".gitignore", in: repo)
            let path = repo.deletingLastPathComponent().appendingPathComponent("ignored files worktree")
            try await service.createWorktree(at: path, branch: "feature", createBranch: true, in: repo)
            let linked = try #require(try await service.worktrees(in: repo).first { !$0.isMain })
            let localSettings = Data("local configuration\n".utf8)
            let artifact = Data([0x00, 0xff, 0x42])
            try localSettings.write(to: path.appendingPathComponent(".env"))
            let build = path.appendingPathComponent("build")
            try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
            try artifact.write(to: build.appendingPathComponent("artifact.bin"))
            #expect(try await GitClient().status(in: path).changes.isEmpty)

            do {
                try await service.removeWorktree(linked, in: repo)
                Issue.record("Removing a worktree containing ignored files must fail")
            } catch let error as GitError {
                #expect(error.stderr.contains("untracked or ignored files"))
                #expect(error.stderr.contains("Back up or remove"))
            }

            #expect(FileManager.default.fileExists(atPath: path.path))
            #expect(try Data(contentsOf: path.appendingPathComponent(".env")) == localSettings)
            #expect(try Data(contentsOf: build.appendingPathComponent("artifact.bin")) == artifact)
            #expect(try await service.worktrees(in: repo).contains { $0.id == linked.id })
        }
    }

    private func createMergeConflict(in repo: URL, service: RepositoryService) async throws {
        try await commit("base\n", file: "conflict.txt", in: repo)
        try await service.createBranch(name: "incoming", in: repo)
        try await commit("incoming\n", file: "conflict.txt", in: repo)
        try await service.switchBranch("main", in: repo)
        try await commit("current\n", file: "conflict.txt", in: repo)
        await #expect(throws: GitError.self) { try await service.merge("incoming", in: repo) }
    }

    @Test func conflictSaveAndMarkAreSeparateAndRejectExternalEdits() async throws {
        try await withRepo { repo, service in
            try await createMergeConflict(in: repo, service: service)
            let document = try await service.conflict(path: "conflict.txt", in: repo)
            #expect(document.canEdit)
            #expect(document.base == "base\n")
            #expect(document.current == "current\n")
            #expect(document.incoming == "incoming\n")
            await #expect(throws: GitError.self) { try await service.continueOperation(in: repo) }
            await #expect(throws: GitError.self) { try await service.createBranch(name: "while-conflicted", in: repo) }
            try await service.saveConflict(document, resolvedText: "resolved\n", in: repo)
            #expect(try await GitClient().status(in: repo).changes.contains { $0.area == .unmerged })
            await #expect(throws: GitError.self) { try await service.markConflictResolved(document, in: repo) }
            let reloaded = try await service.conflict(path: "conflict.txt", in: repo)
            try Data("external\n".utf8).write(to: repo.appendingPathComponent("conflict.txt"))
            await #expect(throws: GitError.self) { try await service.saveConflict(reloaded, resolvedText: "overwrite\n", in: repo) }
            await #expect(throws: GitError.self) { try await service.markConflictResolved(reloaded, in: repo) }
            #expect(try Data(contentsOf: repo.appendingPathComponent("conflict.txt")) == Data("external\n".utf8))
            let external = try await service.conflict(path: "conflict.txt", in: repo)
            try await service.markConflictResolved(external, in: repo)
            try await service.continueOperation(in: repo)
            let context = try await RepositoryContext.resolve(in: repo)
            #expect(RepositoryOperationState.read(in: context) == .normal)
            #expect(try await service.graph(in: repo, limit: 1).first?.parents.count == 2)
        }
    }

    @Test func abortAndDirtyMergeGuardPreserveWorkingFiles() async throws {
        try await withRepo { repo, service in
            try await createMergeConflict(in: repo, service: service)
            try await service.abortOperation(in: repo)
            #expect(try Data(contentsOf: repo.appendingPathComponent("conflict.txt")) == Data("current\n".utf8))
            try Data("dirty\n".utf8).write(to: repo.appendingPathComponent("dirty.txt"))
            await #expect(throws: GitError.self) { try await service.merge("incoming", in: repo) }
            await #expect(throws: GitError.self) { try await service.rebase(onto: "incoming", in: repo) }
            #expect(try Data(contentsOf: repo.appendingPathComponent("dirty.txt")) == Data("dirty\n".utf8))
        }
    }

    @Test func upstreamConfigurationAndCleanRebaseUseExistingGitReferences() async throws {
        try await withRepo { repo, service in
            try await commit("base\n", in: repo)
            try await git(["remote", "add", "origin", repo.path], in: repo)
            try await git(["update-ref", "refs/remotes/origin/main", "HEAD"], in: repo)
            try await service.setUpstream("origin/main", for: "main", in: repo)
            #expect(try await service.branches(in: repo).first { $0.name == "main" }?.upstream == "origin/main")
            #expect(try await service.branches(in: repo).contains { $0.isRemote && $0.name == "origin/main" })
            try await service.setUpstream(nil, for: "main", in: repo)
            #expect(try await service.branches(in: repo).first { $0.name == "main" }?.upstream == nil)
            try await service.createBranch(name: "feature", startPoint: "origin/main", in: repo)
            try await commit("feature\n", file: "feature.txt", in: repo)
            try await service.switchBranch("main", in: repo)
            try await commit("main\n", file: "main.txt", in: repo)
            let main = try await GitClient().headOID(in: repo)
            try await service.switchBranch("feature", in: repo)
            try await service.rebase(onto: "main", in: repo)
            #expect(try await service.graph(in: repo, limit: 1).first?.parents == [main])
        }
    }

    @Test func filteredAndModeChangingConflictsDisableBothMutations() async throws {
        try await withRepo { repo, service in
            try await createMergeConflict(in: repo, service: service)
            try Data("conflict.txt filter=example\n".utf8).write(to: repo.appendingPathComponent(".gitattributes"))
            let filtered = try await service.conflict(path: "conflict.txt", in: repo)
            #expect(!filtered.canEdit)
            #expect(filtered.unavailableReason?.contains("filters") == true)
            await #expect(throws: GitError.self) { try await service.saveConflict(filtered, resolvedText: "unsafe\n", in: repo) }
            await #expect(throws: GitError.self) { try await service.markConflictResolved(filtered, in: repo) }
            try FileManager.default.removeItem(at: repo.appendingPathComponent(".gitattributes"))
            let oid = String(decoding: try await git(["rev-parse", ":2:conflict.txt"], in: repo).stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
            let update = try await TestGitRepository.run(arguments: ["-C", repo.path, "update-index", "--index-info"],
                                                      stdin: Data("100755 \(oid) 2\tconflict.txt\n".utf8))
            #expect(update.exitCode == 0)
            let modes = try await service.conflict(path: "conflict.txt", in: repo)
            #expect(!modes.canEdit)
            #expect(modes.unavailableReason?.contains("modes") == true)
        }
    }

    @Test func divergentRenameConflictRequiresAnExternalTool() async throws {
        try await withRepo { repo, service in
            try await commit("base\n", file: "old.txt", in: repo)
            try await service.createBranch(name: "incoming", in: repo)
            try await git(["mv", "old.txt", "theirs.txt"], in: repo)
            try await GitClient().commit(message: "theirs rename", in: repo)
            try await service.switchBranch("main", in: repo)
            try await git(["mv", "old.txt", "ours.txt"], in: repo)
            try await GitClient().commit(message: "ours rename", in: repo)
            await #expect(throws: GitError.self) { try await service.merge("incoming", in: repo) }
            let document = try await service.conflict(path: "ours.txt", in: repo)
            #expect(!document.canEdit)
            #expect(document.unavailableReason?.contains("rename") == true)
            await #expect(throws: GitError.self) { try await service.saveConflict(document, resolvedText: "unsafe\n", in: repo) }
        }
    }
}
