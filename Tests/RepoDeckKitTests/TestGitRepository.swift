import Foundation
@testable import RepoDeckKit

/// Disposable Git fixtures. Setup commands ignore the developer's global Git
/// configuration; local defaults also protect production clients used by tests.
/// Environment overrides belong to each child process, never the test process.
enum TestGitRepository {
    @discardableResult
    static func run(
        arguments: [String], workingDirectory: URL? = nil,
        environment: [String: String] = [:], stdin: Data? = nil
    ) async throws -> ProcessResult {
        var isolatedEnvironment = environment
        isolatedEnvironment["GIT_CONFIG_NOSYSTEM"] = "1"
        isolatedEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        isolatedEnvironment["GIT_CONFIG_COUNT"] = "0"
        isolatedEnvironment["GIT_CONFIG_PARAMETERS"] = ""
        isolatedEnvironment["GIT_TEMPLATE_DIR"] = ""
        let result = try await ProcessRunner.run(
            arguments: arguments, workingDirectory: workingDirectory,
            environment: isolatedEnvironment, stdin: stdin
        )
        guard result.exitCode == 0, !result.outputTruncated else {
            throw GitError(command: "test git " + arguments.joined(separator: " "),
                           exitCode: result.exitCode, stderr: result.stderr)
        }
        return result
    }

    static func initialize(at repo: URL, bare: Bool = false) async throws {
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try await run(arguments: ["-c", "init.templateDir=", "init", "--template=", "-b", "main"]
                      + (bare ? ["--bare"] : []), workingDirectory: repo)
        try await configure(in: repo)
    }

    static func clone(from source: URL, to destination: URL, bare: Bool = false) async throws {
        try await run(arguments: ["-c", "core.hooksPath=/dev/null", "-c", "init.templateDir=",
                                  "clone", "--template="] + (bare ? ["--bare"] : [])
                      + [source.path, destination.path])
        try await configure(in: destination)
    }

    static func configure(in repo: URL) async throws {
        // This is a fixture-owned include, written once rather than launching a
        // subprocess for each default. Later test-specific local settings win.
        let result = try await run(arguments: ["-C", repo.path, "rev-parse", "--absolute-git-dir"])
        let gitDir = URL(fileURLWithPath: String(decoding: result.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines), isDirectory: true)
        let defaults = gitDir.appendingPathComponent("repodeck-test-defaults.config")
        try """
        [user]
            name = Test
            email = test@example.com
        [commit]
            gpgSign = false
        [tag]
            gpgSign = false
        [core]
            hooksPath = /dev/null
            fsmonitor = false
            autocrlf = false
            excludesFile = /dev/null
            attributesFile = /dev/null
        [init]
            templateDir =
        [color]
            ui = false
        [diff]
            mnemonicPrefix = false
            noprefix = false
        [log]
            showSignature = false
        [maintenance]
            auto = false
        [gc]
            auto = 0

        """.write(to: defaults, atomically: true, encoding: .utf8)
        try await run(arguments: ["-C", repo.path, "config", "--local", "--add", "include.path", defaults.path])
    }

    static func withRepository(
        baseContent: String? = nil,
        _ body: (URL, GitClient) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("repodeck-test-\(UUID().uuidString)", isDirectory: true)
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await initialize(at: repo)
        if let baseContent {
            try baseContent.write(to: repo.appendingPathComponent("base.txt"), atomically: true, encoding: .utf8)
            try await run(arguments: ["-C", repo.path, "add", "-A"])
            try await run(arguments: ["-C", repo.path, "commit", "-m", "chore: base"])
        }
        try await body(repo, GitClient())
    }

    static func withSharedRemote(
        _ body: (URL, URL, URL, GitClient) async throws -> Void
    ) async throws {
        try await withRepository(baseContent: "base\n") { seed, client in
            let root = seed.deletingLastPathComponent()
            let remote = root.appendingPathComponent("remote.git")
            let ours = root.appendingPathComponent("ours")
            let theirs = root.appendingPathComponent("theirs")
            try await clone(from: seed, to: remote, bare: true)
            try await clone(from: remote, to: ours)
            try await clone(from: remote, to: theirs)
            try await body(remote, ours, theirs, client)
        }
    }
}
