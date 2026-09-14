import Darwin
import Foundation
import Testing
import RepoDeckKit
@testable import RepoDeckCore

private final class CoreGitFixture: @unchecked Sendable {
    let root: URL
    let hooks: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("RepoDeckCore-\(UUID().uuidString)").resolvingSymlinksInPath()
        hooks = root.appendingPathComponent("empty-hooks")
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        _ = try git(["-c", "init.templateDir=", "init", "-b", "main"])
        for (key, value) in ["user.name": "Test", "user.email": "test@example.invalid", "commit.gpgsign": "false", "tag.gpgsign": "false", "core.hooksPath": hooks.path, "core.excludesFile": "/dev/null", "core.autocrlf": "false", "core.fsmonitor": "false"] {
            _ = try git(["config", key, value])
        }
        try Data("initial\n".utf8).write(to: root.appendingPathComponent("file.txt"))
        _ = try git(["add", "file.txt"])
        _ = try git(["commit", "-m", "Initial"])
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    @discardableResult func git(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: GitDefaults.gitPath)
        process.arguments = ["-C", root.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NSError(domain: "FixtureGit", code: Int(process.terminationStatus)) }
        return String(decoding: data, as: UTF8.self)
    }
}

private actor ScanGate {
    var calls: [[URL]] = []
    var continuation: CheckedContinuation<Void, Never>?
    func scan(_ roots: [URL]) async -> [Repo] {
        calls.append(roots)
        if calls.count == 1 { await withCheckedContinuation { continuation = $0 } }
        return []
    }
    func release() { continuation?.resume(); continuation = nil }
}

@Suite("Application state")
@MainActor
struct AppStateTests {
    @Test func folderChangesDuringScanAreNotLost() async throws {
        let gate = ScanGate()
        let preferences = UserDefaults(suiteName: "RepoDeckTests-\(UUID().uuidString)")!
        let model = AppModel(preferences: preferences, scanner: { await gate.scan($0) }, startServices: false)
        let first = Task { await model.rescan() }
        while await gate.calls.isEmpty { await Task.yield() }
        let added = URL(fileURLWithPath: "/private/tmp/added-repository-root")
        model.addFolders([added])
        await model.rescan()
        await gate.release()
        await first.value
        let calls = await gate.calls
        #expect(calls.count == 2)
        #expect(calls.last == [added])
        #expect(!model.isScanning)
    }

    @Test func identityReadFailureIsNotReportedAsMissingConfiguration() async throws {
        let fixture = try CoreGitFixture()
        let vm = RepoViewModel(repo: Repo(path: fixture.root), client: GitClient())
        await vm.refreshIdentity()
        let previous = try #require(vm.gitIdentity)
        #expect(vm.hasLoadedIdentity)
        vm.client = GitClient(gitPath: fixture.root.appendingPathComponent("missing-git").path)
        await vm.refreshIdentity()
        #expect(vm.identityLoadError != nil)
        #expect(vm.gitIdentity == previous)
        #expect(!vm.isLoadingIdentity)
    }

    @Test func externalConfigurationChangeRefreshesTheAuthorFooter() async throws {
        let fixture = try CoreGitFixture()
        let vm = RepoViewModel(repo: Repo(path: fixture.root), client: GitClient())
        await vm.refreshIdentity()
        try fixture.git(["config", "--local", "user.name", "Updated Author"])
        await vm.refreshForExternalChange()
        #expect(vm.gitIdentity?.name == "Updated Author")
        #expect(vm.identityLoadError == nil)
    }

    @Test func commitPreservesNewDraftWhileHookRuns() async throws {
        let fixture = try CoreGitFixture()
        let marker = fixture.root.appendingPathComponent("hook-started")
        let release = fixture.root.appendingPathComponent("hook-release")
        let hook = fixture.hooks.appendingPathComponent("pre-commit")
        try "#!/bin/sh\ntouch hook-started\nwhile [ ! -f hook-release ]; do sleep 0.02; done\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        try Data("changed\n".utf8).write(to: fixture.root.appendingPathComponent("file.txt"))
        try fixture.git(["add", "file.txt"])
        let vm = RepoViewModel(repo: Repo(path: fixture.root), client: GitClient())
        await vm.refreshStatus()
        vm.commitMessage = "Submitted message"
        let task = Task { await vm.commit() }
        // A full parallel suite may queue this command behind other jobs.
        // Cleanup is checked separately after the child has actually started.
        let deadline = ContinuousClock.now + .seconds(30)
        while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        vm.commitMessage = "My next draft"
        try Data().write(to: release)
        let result = await task.value
        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(result == .succeeded)
        #expect(vm.commitMessage == "My next draft")
        #expect(try fixture.git(["log", "-1", "--format=%s"]).trimmingCharacters(in: .whitespacesAndNewlines) == "Submitted message")
    }

    @Test func bulkSyncReportsBusyRepositoriesAsSkipped() async throws {
        let fixture = try CoreGitFixture()
        let vm = RepoViewModel(repo: Repo(path: fixture.root), client: GitClient())
        vm.isBusy = true
        let model = AppModel(preferences: UserDefaults(suiteName: "RepoDeckTests-\(UUID().uuidString)")!, startServices: false)
        model.repos = [vm]
        await model.fetchAll()
        #expect(model.bulkSummary?.skipped == 1)
        #expect(model.bulkSummary?.succeeded == 0)
        #expect(model.bulkSummary?.needsAttention == true)
        #expect(model.bulkSummary?.repositories.first?.id == vm.id)
        #expect(model.bulkSummary?.repositories.first?.result == .skipped("Repository is busy"))
    }

    @Test func bulkSyncRetainsResultsForTheOriginalRepositories() async throws {
        let successful = try CoreGitFixture()
        let failed = try CoreGitFixture()
        let busy = try CoreGitFixture()
        try successful.git(["remote", "add", "origin", successful.root.path])
        try failed.git(["remote", "add", "origin", failed.root.appendingPathComponent("missing-remote").path])
        let models = [successful, failed, busy].map { RepoViewModel(repo: Repo(path: $0.root), client: GitClient()) }
        models[2].isBusy = true
        let model = AppModel(preferences: UserDefaults(suiteName: "RepoDeckTests-\(UUID().uuidString)")!, startServices: false)
        model.repos = models
        await model.fetchAll()
        let summary = try #require(model.bulkSummary)
        #expect(summary.repositories.map(\.id) == models.map(\.id))
        #expect(summary.succeeded == 1)
        #expect(summary.failed == 1)
        #expect(summary.skipped == 1)
        #expect(summary.needsAttention)
        #expect(summary.repositories[0].result == .succeeded)
        guard case .failed(let reason) = summary.repositories[1].result else {
            Issue.record("The failed remote was not reported for its repository")
            return
        }
        #expect(reason.contains("missing-remote"))
        #expect(summary.repositories[2].result == .skipped("Repository is busy"))
        models[1].actionError = nil
        model.repos = []
        #expect(model.bulkSummary == summary)
        #expect(model.bulkProgress == nil)
    }

    @Test func successfulBulkSyncDoesNotNeedAttention() async throws {
        let fixture = try CoreGitFixture()
        try fixture.git(["remote", "add", "origin", fixture.root.path])
        let model = AppModel(preferences: UserDefaults(suiteName: "RepoDeckTests-\(UUID().uuidString)")!, startServices: false)
        model.repos = [RepoViewModel(repo: Repo(path: fixture.root), client: GitClient())]
        await model.fetchAll()
        let summary = try #require(model.bulkSummary)
        #expect(summary.succeeded == 1)
        #expect(!summary.needsAttention)
        #expect(summary.text == "Fetch All: 1 succeeded, 0 failed, 0 skipped")
    }

    @Test func cancelledCommandKeepsRepositoryLockedUntilProcessCleanupFinishes() async throws {
        let fixture = try CoreGitFixture()
        let first = RepoViewModel(repo: Repo(path: fixture.root), client: GitClient())
        let second = RepoViewModel(repo: Repo(path: fixture.root), client: GitClient())
        await first.refreshStatus()
        await second.refreshStatus()
        let ready = fixture.root.appendingPathComponent(".command-ready")
        let pidFile = fixture.root.appendingPathComponent(".command-pid")
        let lateWrite = fixture.root.appendingPathComponent(".command-late-write")
        first.commandInput = """
        exec /bin/sh -c 'trap "" TERM; echo $$ > .command-pid; touch .command-ready; sleep 0.25; printf "cancelled command\\n" > file.txt; touch .command-late-write; sleep 30'
        """
        first.runCommand()
        defer { first.cancelCommand() }
        let deadline = ContinuousClock.now + .seconds(5)
        while !FileManager.default.fileExists(atPath: ready.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(FileManager.default.fileExists(atPath: ready.path))
        let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        first.cancelCommand()

        // A second view model uses the same shared repository coordinator. It
        // must wait while the TERM-resistant command can still modify files.
        let replacement = Data("second mutation\n".utf8)
        let result = await second.performAction {
            #expect(kill(pid, 0) == -1 && errno == ESRCH)
            #expect(FileManager.default.fileExists(atPath: lateWrite.path))
            try replacement.write(to: fixture.root.appendingPathComponent("file.txt"))
            try await second.client.stage(["file.txt"], in: fixture.root)
        }
        #expect(result == .succeeded)
        #expect(!first.isRunningCommand)
        #expect(try Data(contentsOf: fixture.root.appendingPathComponent("file.txt")) == replacement)
        #expect(try fixture.git(["show", ":file.txt"]) == "second mutation\n")
    }

    @Test func externalCommitUpdatesHistoryAndStashes() async throws {
        let fixture = try CoreGitFixture()
        let vm = RepoViewModel(repo: Repo(path: fixture.root), client: GitClient())
        await vm.refreshForExternalChange()
        #expect(vm.commits.first?.subject == "Initial")
        try Data("second\n".utf8).write(to: fixture.root.appendingPathComponent("file.txt"))
        try fixture.git(["commit", "-am", "External commit"])
        await vm.refreshForExternalChange()
        #expect(vm.commits.first?.subject == "External commit")
        try Data("stash\n".utf8).write(to: fixture.root.appendingPathComponent("file.txt"))
        try fixture.git(["stash", "push", "-m", "External stash"])
        await vm.refreshForExternalChange()
        #expect(vm.stashes.count == 1)
    }

    @Test func incompatibleActionRefusesExistingMerge() async throws {
        let fixture = try CoreGitFixture()
        let context = try await RepositoryContext.resolve(in: fixture.root)
        try Data("placeholder\n".utf8).write(to: context.gitDir.appendingPathComponent("MERGE_HEAD"))
        let vm = RepoViewModel(repo: Repo(path: fixture.root), client: GitClient())
        var executed = false
        let result = await vm.performAction { executed = true }
        #expect(!executed)
        if case .failed = result {} else { Issue.record("Expected existing operation to block action") }
        #expect(vm.operationState == .merge)
    }

    @Test func staleBranchPreviewDoesNotExecuteOnAnotherBranchAtSameCommit() async throws {
        let fixture = try CoreGitFixture()
        let vm = RepoViewModel(repo: Repo(path: fixture.root), client: GitClient())
        await vm.refreshForExternalChange()
        let preview = vm.operationIdentity
        try fixture.git(["switch", "-c", "other"])
        var executed = false
        let result = await vm.performAction(expectedIdentity: preview) { executed = true }
        #expect(!executed)
        if case .failed = result {} else { Issue.record("Expected stale branch preview rejection") }
        #expect(vm.status?.branch == "other")
    }

    @Test func staleDisplayedHunkDoesNotStageOldContents() async throws {
        let fixture = try CoreGitFixture()
        let vm = RepoViewModel(repo: Repo(path: fixture.root), client: GitClient())
        let file = fixture.root.appendingPathComponent("file.txt")
        try Data("first edit\n".utf8).write(to: file)
        let diff = try #require(try await vm.client.diff(path: "file.txt", staged: false, in: fixture.root))
        try Data("new external edit\n".utf8).write(to: file)
        await vm.stageHunk(try #require(diff.hunks.first), in: diff)
        #expect(vm.actionError?.stderr.contains("diff changed") == true)
        #expect(try fixture.git(["show", ":file.txt"]) == "initial\n")
        #expect(try Data(contentsOf: file) == Data("new external edit\n".utf8))
    }

    @Test func replacedOperationAtSameHeadInvalidatesAbortPreview() async throws {
        let fixture = try CoreGitFixture()
        let vm = RepoViewModel(repo: Repo(path: fixture.root), client: GitClient())
        await vm.refreshForExternalChange()
        let context = try #require(vm.context)
        let head = try fixture.git(["rev-parse", "HEAD"])
        try Data(head.utf8).write(to: context.gitDir.appendingPathComponent("MERGE_HEAD"))
        let preview = vm.operationIdentity
        try Data((head + head).utf8).write(to: context.gitDir.appendingPathComponent("MERGE_HEAD"))
        var executed = false
        let result = await vm.performAction(allowInProgress: true, expectedIdentity: preview) { executed = true }
        #expect(!executed)
        if case .failed = result {} else { Issue.record("Expected changed operation rejection") }
    }

    @Test func conflictDraftCannotWriteDifferentSelectedFile() async throws {
        let fixture = try CoreGitFixture()
        try fixture.git(["switch", "-c", "incoming"])
        try Data("incoming\n".utf8).write(to: fixture.root.appendingPathComponent("file.txt"))
        try fixture.git(["commit", "-am", "Incoming"])
        try fixture.git(["switch", "main"])
        try Data("current\n".utf8).write(to: fixture.root.appendingPathComponent("file.txt"))
        try fixture.git(["commit", "-am", "Current"])
        do { try fixture.git(["merge", "incoming"]) } catch {}
        let vm = RepoViewModel(repo: Repo(path: fixture.root), client: GitClient())
        await vm.refreshForExternalChange()
        await vm.workspace.loadConflict("file.txt", using: vm)
        #expect(vm.workspace.conflictDocument != nil)
        let before = try Data(contentsOf: fixture.root.appendingPathComponent("file.txt"))
        vm.workspace.selectedConflict = "next-file.txt"
        vm.workspace.resolution = "resolution for next file\n"
        await vm.workspace.saveResolution(using: vm)
        await vm.workspace.markResolved(using: vm)
        #expect(try Data(contentsOf: fixture.root.appendingPathComponent("file.txt")) == before)
        #expect(try await vm.client.status(in: fixture.root).changes.contains { $0.area == .unmerged })
    }
}
