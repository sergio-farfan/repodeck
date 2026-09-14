import Foundation
import Testing
import RepoDeckKit
@testable import RepoDeckCore

/// Every subprocess, including the view model's refreshes, uses this temporary
/// global configuration. These tests never read or write the user's defaults.
private final class IdentityEditorFixture: @unchecked Sendable {
    let root: URL
    let repository: URL
    let executable: URL
    var client: GitClient { GitClient(gitPath: executable.path) }

    init() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("RepoDeckIdentityEditor-\(UUID().uuidString)").resolvingSymlinksInPath()
        repository = root.appendingPathComponent("repository")
        executable = root.appendingPathComponent("git")
        let globalConfig = root.appendingPathComponent("global.gitconfig")
        let hooks = root.appendingPathComponent("empty-hooks")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        try Data().write(to: globalConfig)
        let script = """
        #!/bin/sh
        unset GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
        unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE EMAIL
        export GIT_CONFIG_GLOBAL=\(Self.quote(globalConfig.path))
        export GIT_CONFIG_NOSYSTEM=1
        export GIT_TERMINAL_PROMPT=0
        exec \(Self.quote(GitDefaults.gitPath)) "$@"
        """
        try (script + "\n").write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try await git(["-c", "init.templateDir=", "init", "-b", "main"])
        for (key, value) in ["user.name": "Local Author", "user.email": "local@example.invalid", "commit.gpgsign": "false", "tag.gpgsign": "false", "core.hooksPath": hooks.path, "core.excludesFile": "/dev/null", "core.autocrlf": "false", "core.fsmonitor": "false"] {
            try await git(["config", "--local", key, value])
        }
        try Data("initial\n".utf8).write(to: repository.appendingPathComponent("file.txt"))
        try await git(["add", "file.txt"])
        try await git(["commit", "-m", "Initial"])
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    @discardableResult func git(_ arguments: [String]) async throws -> String {
        let result = try await ProcessRunner.run(executable.path, arguments: ["-C", repository.path] + arguments)
        guard result.exitCode == 0 else {
            throw GitError(command: "Identity fixture Git", exitCode: result.exitCode, stderr: result.stderr)
        }
        return String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private actor IdentityEditorGate {
    private var calls = 0
    private var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func pause(onCall: Int = 1) async {
        calls += 1
        guard calls == onCall else { return }
        entered = true
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilEntered() async -> Bool {
        let deadline = ContinuousClock.now + .seconds(30)
        while !entered, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return entered
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

@Suite("Git identity editor")
@MainActor
struct GitIdentityEditorTests {
    private func viewModel(_ fixture: IdentityEditorFixture) -> RepoViewModel {
        RepoViewModel(repo: Repo(path: fixture.repository), client: fixture.client)
    }

    @Test func repositoryMayStartFromDefaultsButGlobalScopeNeverInheritsLocalValues() async throws {
        let fixture = try await IdentityEditorFixture()
        try await fixture.git(["config", "--local", "--unset", "user.name"])
        try await fixture.git(["config", "--global", "user.name", "Default Author"])
        let editor = GitIdentityEditor(repo: viewModel(fixture))
        await editor.load()
        #expect(editor.scope == .repository)
        #expect(editor.name == "Default Author")
        #expect(editor.email == "local@example.invalid")
        #expect(editor.hasLoaded)
        await editor.selectScope(.globalDefault)
        #expect(editor.name == "Default Author")
        #expect(editor.email.isEmpty)
        #expect(!editor.canSave)
        #expect(editor.effectiveIdentity?.email == "local@example.invalid")
    }

    @Test func scopeDraftsRemainSeparateAndSurviveSwitching() async throws {
        let fixture = try await IdentityEditorFixture()
        let editor = GitIdentityEditor(repo: viewModel(fixture))
        await editor.load()
        editor.name = "Repository draft"
        editor.email = "repository-draft@example.invalid"
        await editor.selectScope(.globalDefault)
        #expect(editor.name.isEmpty)
        #expect(editor.email.isEmpty)
        editor.name = "Default draft"
        editor.email = "default-draft@example.invalid"
        await editor.selectScope(.repository)
        #expect(editor.name == "Repository draft")
        #expect(editor.email == "repository-draft@example.invalid")
        await editor.selectScope(.globalDefault)
        #expect(editor.name == "Default draft")
        #expect(editor.email == "default-draft@example.invalid")
        let unchanged = try await fixture.client.configuredIdentity(in: fixture.repository, scope: .globalDefault)
        #expect(unchanged == GitIdentity(name: nil, email: nil))
    }

    @Test func slowReadPreservesNewerDraft() async throws {
        let fixture = try await IdentityEditorFixture()
        let gate = IdentityEditorGate()
        var io = GitIdentityEditorIO.live
        io.readScope = { client, scope, path in
            await gate.pause()
            return try await client.configuredIdentity(in: path, scope: scope)
        }
        let editor = GitIdentityEditor(repo: viewModel(fixture), io: io)
        let load = Task { await editor.load() }
        let entered = await gate.waitUntilEntered()
        editor.name = "Typed while loading"
        editor.email = "draft@example.invalid"
        await gate.release()
        await load.value
        #expect(entered)
        #expect(editor.name == "Typed while loading")
        #expect(editor.email == "draft@example.invalid")
        #expect(editor.hasLoaded)
        #expect(editor.error == nil)
    }

    @Test func obsoleteScopeReadCannotReplaceSelectedScopeOrDraft() async throws {
        let fixture = try await IdentityEditorFixture()
        try await fixture.git(["config", "--global", "user.name", "Default Author"])
        let gate = IdentityEditorGate()
        var io = GitIdentityEditorIO.live
        io.readScope = { client, scope, path in
            if scope == .repository { await gate.pause() }
            return try await client.configuredIdentity(in: path, scope: scope)
        }
        let editor = GitIdentityEditor(repo: viewModel(fixture), io: io)
        let load = Task { await editor.load() }
        let entered = await gate.waitUntilEntered()
        await editor.selectScope(.globalDefault)
        editor.email = "default-draft@example.invalid"
        await gate.release()
        await load.value
        #expect(entered)
        #expect(editor.scope == .globalDefault)
        #expect(editor.name == "Default Author")
        #expect(editor.email == "default-draft@example.invalid")
        #expect(editor.hasLoaded)
        #expect(!editor.isLoading)
    }

    @Test func slowSaveKeepsCapturedDestinationAndPreservesNewerDraft() async throws {
        let fixture = try await IdentityEditorFixture()
        let gate = IdentityEditorGate()
        var io = GitIdentityEditorIO.live
        io.write = { client, name, email, scope, path in
            await gate.pause()
            try await client.setConfiguredIdentity(name: name, email: email, scope: scope, in: path)
        }
        let editor = GitIdentityEditor(repo: viewModel(fixture), io: io)
        await editor.load()
        editor.name = "Submitted Author"
        editor.email = "submitted@example.invalid"
        let save = Task { await editor.save() }
        let entered = await gate.waitUntilEntered()
        editor.name = "Next Author"
        editor.email = "next@example.invalid"
        await editor.selectScope(.globalDefault)
        await gate.release()
        let saved = await save.value
        #expect(entered)
        #expect(saved)
        #expect(editor.scope == .repository)
        #expect(editor.name == "Next Author")
        #expect(editor.email == "next@example.invalid")
        #expect(editor.notice?.contains("newer edits") == true)
        let actual = try await fixture.client.configuredIdentity(in: fixture.repository, scope: .repository)
        let defaults = try await fixture.client.configuredIdentity(in: fixture.repository, scope: .globalDefault)
        #expect(actual == GitIdentity(name: "Submitted Author", email: "submitted@example.invalid"))
        #expect(defaults == GitIdentity(name: nil, email: nil))
    }

    @Test func partialSaveFailureRetainsDraftAndRefreshesActualIdentity() async throws {
        let fixture = try await IdentityEditorFixture()
        var io = GitIdentityEditorIO.live
        io.write = { _, name, _, _, _ in
            try await fixture.git(["config", "--local", "user.name", name])
            throw GitError(command: "git config user.email", exitCode: 1, stderr: "Injected second write failure")
        }
        let vm = viewModel(fixture)
        let editor = GitIdentityEditor(repo: vm, io: io)
        await editor.load()
        editor.name = "Partly Saved Author"
        editor.email = "desired@example.invalid"
        let saved = await editor.save()
        #expect(!saved)
        #expect(editor.name == "Partly Saved Author")
        #expect(editor.email == "desired@example.invalid")
        #expect(editor.effectiveIdentity == GitIdentity(name: "Partly Saved Author", email: "local@example.invalid"))
        #expect(vm.gitIdentity == editor.effectiveIdentity)
        #expect(editor.error?.contains("Injected second write failure") == true)
        #expect(!editor.hasLoaded)
        #expect(!editor.canSave)
        await editor.load()
        #expect(editor.hasLoaded)
        #expect(editor.email == "desired@example.invalid")
    }

    @Test func changedConfigurationIsRejectedBeforeOverwritingExternalEdit() async throws {
        let fixture = try await IdentityEditorFixture()
        let editor = GitIdentityEditor(repo: viewModel(fixture))
        await editor.load()
        editor.name = "Draft Author"
        editor.email = "draft@example.invalid"
        try await fixture.git(["config", "--local", "user.email", "external@example.invalid"])
        let saved = await editor.save()
        #expect(!saved)
        #expect(editor.error?.contains("changed since this form was loaded") == true)
        #expect(editor.email == "draft@example.invalid")
        let actual = try await fixture.client.configuredIdentity(in: fixture.repository, scope: .repository)
        #expect(actual == GitIdentity(name: "Local Author", email: "external@example.invalid"))
    }

    @Test func changedBranchAtSameCommitIsRejectedBeforeWriting() async throws {
        let fixture = try await IdentityEditorFixture()
        let editor = GitIdentityEditor(repo: viewModel(fixture))
        await editor.load()
        editor.name = "Draft Author"
        editor.email = "draft@example.invalid"
        try await fixture.git(["switch", "-c", "other"])
        let saved = await editor.save()
        #expect(!saved)
        #expect(editor.error != nil)
        #expect(editor.name == "Draft Author")
        let actual = try await fixture.client.configuredIdentity(in: fixture.repository, scope: .repository)
        #expect(actual == GitIdentity(name: "Local Author", email: "local@example.invalid"))
    }

    @Test func changedExecutableMakesReloadAvailableWithoutWriting() async throws {
        let fixture = try await IdentityEditorFixture()
        let vm = viewModel(fixture)
        let editor = GitIdentityEditor(repo: vm)
        await editor.load()
        editor.name = "Draft Author"
        vm.client = GitClient(gitPath: fixture.root.appendingPathComponent("missing-git").path)
        let saved = await editor.save()
        #expect(!saved)
        #expect(!editor.hasLoaded)
        #expect(editor.error?.contains("executable changed") == true)
        let actual = try await fixture.client.configuredIdentity(in: fixture.repository, scope: .repository)
        #expect(actual.name == "Local Author")
    }

    @Test func executableChangeDuringPrewriteReadCannotUseCapturedTool() async throws {
        let fixture = try await IdentityEditorFixture()
        let gate = IdentityEditorGate()
        var io = GitIdentityEditorIO.live
        io.readScope = { client, scope, path in
            await gate.pause(onCall: 2)
            return try await client.configuredIdentity(in: path, scope: scope)
        }
        let vm = viewModel(fixture)
        let editor = GitIdentityEditor(repo: vm, io: io)
        await editor.load()
        editor.name = "Draft Author"
        let save = Task { await editor.save() }
        let entered = await gate.waitUntilEntered()
        vm.client = GitClient(gitPath: fixture.root.appendingPathComponent("missing-git").path)
        await gate.release()
        let saved = await save.value
        #expect(entered)
        #expect(!saved)
        #expect(editor.error?.contains("executable changed") == true)
        let actual = try await fixture.client.configuredIdentity(in: fixture.repository, scope: .repository)
        #expect(actual.name == "Local Author")
    }

    @Test func successfulCommandWithoutMatchingReadbackIsNotReportedAsSaved() async throws {
        let fixture = try await IdentityEditorFixture()
        var io = GitIdentityEditorIO.live
        io.write = { _, _, _, _, _ in }
        let editor = GitIdentityEditor(repo: viewModel(fixture), io: io)
        await editor.load()
        editor.name = "Unverified Author"
        let saved = await editor.save()
        #expect(!saved)
        #expect(editor.notice == nil)
        #expect(editor.error?.contains("verification failed") == true)
        #expect(editor.name == "Unverified Author")
        #expect(editor.effectiveIdentity?.name == "Local Author")
    }

    @Test func busyRepositoryIsNotReportedAsSaved() async throws {
        let fixture = try await IdentityEditorFixture()
        let vm = viewModel(fixture)
        let editor = GitIdentityEditor(repo: vm)
        await editor.load()
        editor.name = "Draft Author"
        vm.isBusy = true
        let saved = await editor.save()
        #expect(!saved)
        #expect(editor.error?.contains("busy") == true)
        #expect(editor.notice == nil)
        let actual = try await fixture.client.configuredIdentity(in: fixture.repository, scope: .repository)
        #expect(actual.name == "Local Author")
    }

    @Test func defaultSaveExplainsLocalOverrideAndLaterEditsClearSuccessNotice() async throws {
        let fixture = try await IdentityEditorFixture()
        let editor = GitIdentityEditor(repo: viewModel(fixture))
        await editor.selectScope(.globalDefault)
        editor.name = "Default Author"
        editor.email = "default@example.invalid"
        let saved = await editor.save()
        #expect(saved)
        #expect(editor.notice?.contains("different author") == true)
        #expect(editor.effectiveIdentity == GitIdentity(name: "Local Author", email: "local@example.invalid"))
        #expect(!editor.canSave)
        let actual = try await fixture.client.configuredIdentity(in: fixture.repository, scope: .globalDefault)
        #expect(actual == GitIdentity(name: "Default Author", email: "default@example.invalid"))
        editor.name = "Another draft"
        #expect(editor.notice == nil)
        #expect(editor.canSave)
    }

    @Test func failedInitialReadPreservesDraftAndDoesNotClaimMissingIdentity() async throws {
        let fixture = try await IdentityEditorFixture()
        var io = GitIdentityEditorIO.live
        io.readScope = { _, _, _ in
            throw GitError(command: "git config", exitCode: 1, stderr: "Configuration cannot be read")
        }
        let editor = GitIdentityEditor(repo: viewModel(fixture), io: io)
        editor.name = "Existing draft"
        editor.email = "draft@example.invalid"
        await editor.load()
        #expect(!editor.hasLoaded)
        #expect(!editor.canSave)
        #expect(editor.error?.contains("cannot be read") == true)
        #expect(editor.effectiveIdentity == nil)
        #expect(editor.name == "Existing draft")
        let saved = await editor.save()
        #expect(!saved)
    }

    @Test func invalidRawInputDoesNotWriteEitherField() async throws {
        let fixture = try await IdentityEditorFixture()
        let editor = GitIdentityEditor(repo: viewModel(fixture))
        await editor.load()
        editor.name = "Changed Author"
        editor.email = "email@example.invalid\n"
        let saved = await editor.save()
        #expect(!saved)
        #expect(editor.email == "email@example.invalid\n")
        let actual = try await fixture.client.configuredIdentity(in: fixture.repository, scope: .repository)
        #expect(actual == GitIdentity(name: "Local Author", email: "local@example.invalid"))
    }

    @Test func unresolvedAuthorDoesNotBlockConfigurationRepair() async throws {
        let fixture = try await IdentityEditorFixture()
        try await fixture.git(["config", "--local", "--unset", "user.name"])
        try await fixture.git(["config", "--local", "--unset", "user.email"])
        try await fixture.git(["config", "--local", "user.useConfigOnly", "true"])
        let vm = viewModel(fixture)
        await vm.refreshIdentity()
        #expect(vm.gitIdentity == nil)
        #expect(vm.identityLoadError != nil)
        let editor = GitIdentityEditor(repo: vm)
        await editor.load()
        #expect(editor.hasLoaded)
        #expect(editor.error == nil)
        #expect(editor.effectiveIdentity == nil)
        #expect(editor.effectiveIdentityError != nil)
        #expect(editor.name.isEmpty)
        #expect(editor.email.isEmpty)
        editor.name = "Repaired Author"
        editor.email = "repaired@example.invalid"
        #expect(editor.canSave)
        #expect(await editor.save())
        #expect(editor.effectiveIdentity == GitIdentity(name: "Repaired Author", email: "repaired@example.invalid"))
        #expect(editor.effectiveIdentityError == nil)
        #expect(vm.gitIdentity == editor.effectiveIdentity)
        #expect(vm.identityLoadError == nil)
    }

    @Test func footerAndSaveVerificationUseAuthorOverrideWithoutCopyingItIntoDefaults() async throws {
        let fixture = try await IdentityEditorFixture()
        for key in ["user.name", "user.email"] {
            try await fixture.git(["config", "--local", "--unset", key])
        }
        try await fixture.git(["config", "--local", "author.name", "Override Author"])
        try await fixture.git(["config", "--local", "author.email", "override@example.invalid"])
        let vm = viewModel(fixture)
        await vm.refreshIdentity()
        let override = GitIdentity(name: "Override Author", email: "override@example.invalid")
        #expect(vm.gitIdentity == override)
        #expect(vm.identityLoadError == nil)
        let editor = GitIdentityEditor(repo: vm)
        await editor.load()
        #expect(editor.name.isEmpty)
        #expect(editor.email.isEmpty)
        #expect(editor.effectiveIdentity == override)
        editor.name = "New Default"
        editor.email = "new-default@example.invalid"
        #expect(await editor.save())
        #expect(editor.effectiveIdentity == override)
        #expect(vm.gitIdentity == override)
        #expect(editor.notice?.contains("different author") == true)
        #expect(try await fixture.client.configuredIdentity(in: fixture.repository, scope: .repository)
            == GitIdentity(name: "New Default", email: "new-default@example.invalid"))
        try await fixture.git(["config", "--local", "author.name", "External Author"])
        await vm.refreshForExternalChange()
        #expect(vm.gitIdentity?.name == "External Author")
    }

    @Test func savedDefaultsDoNotClaimToRepairInvalidAuthorOverride() async throws {
        let fixture = try await IdentityEditorFixture()
        try await fixture.git(["config", "--local", "author.name", "<>"])
        let editor = GitIdentityEditor(repo: viewModel(fixture))
        await editor.load()
        #expect(editor.hasLoaded)
        #expect(editor.effectiveIdentityError != nil)
        editor.name = "Saved Default"
        #expect(await editor.save())
        #expect(editor.error == nil)
        #expect(editor.effectiveIdentity == nil)
        #expect(editor.effectiveIdentityError != nil)
        #expect(editor.notice?.contains("still cannot resolve") == true)
        #expect(!editor.canSave)
        #expect(try await fixture.client.configuredIdentity(in: fixture.repository, scope: .repository).name == "Saved Default")
        try await fixture.git(["config", "--local", "--unset", "author.name"])
        await editor.load()
        #expect(editor.effectiveIdentityError == nil)
        #expect(editor.effectiveIdentity?.name == "Saved Default")
    }

    @Test func cancelledAuthorReadDoesNotEnableSaving() async throws {
        let fixture = try await IdentityEditorFixture()
        var io = GitIdentityEditorIO.live
        io.readEffective = { _, _ in throw CancellationError() }
        let editor = GitIdentityEditor(repo: viewModel(fixture), io: io)
        await editor.load()
        #expect(!editor.hasLoaded)
        #expect(!editor.isLoading)
        #expect(editor.error?.contains("cancelled") == true)
        #expect(editor.effectiveIdentityError == nil)
    }
}
