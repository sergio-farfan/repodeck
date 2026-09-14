import Foundation
import Testing
@testable import RepoDeckKit

@Suite struct TestGitRepositoryTests {
    @Test func fixturesOverrideDeveloperHooksIgnoresAndLineEndingSettings() async throws {
        try await TestGitRepository.withRepository { repo, _ in
            let root = repo.deletingLastPathComponent()
            let hooks = root.appendingPathComponent("hostile-hooks")
            try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
            let hook = hooks.appendingPathComponent("pre-commit")
            try "#!/bin/sh\nexit 71\n".write(to: hook, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
            let excludes = root.appendingPathComponent("developer-excludes")
            try "*.txt\n".write(to: excludes, atomically: true, encoding: .utf8)
            let globalConfig = root.appendingPathComponent("developer.gitconfig")
            try """
            [core]
                hooksPath = \(hooks.path)
                excludesFile = \(excludes.path)
                autocrlf = true
            [commit]
                gpgSign = true
            [alias]
                fixture-alias = !exit 71

            """.write(to: globalConfig, atomically: true, encoding: .utf8)
            let environment = ["GIT_CONFIG_GLOBAL": globalConfig.path, "GIT_CONFIG_NOSYSTEM": "1"]
            let content = Data("first\r\nsecond\r\n".utf8)
            try content.write(to: repo.appendingPathComponent("sample.txt"))
            // Deliberately bypass the isolated setup runner. These subprocesses
            // see hostile global settings, as production GitClient calls would.
            let add = try await ProcessRunner.run(arguments: ["-C", repo.path, "add", "sample.txt"], environment: environment)
            try #require(add.exitCode == 0, "\(add.stderr)")
            let commit = try await ProcessRunner.run(arguments: ["-C", repo.path, "commit", "-m", "fixture"], environment: environment)
            try #require(commit.exitCode == 0, "\(commit.stderr)")
            let blob = try await TestGitRepository.run(arguments: ["-C", repo.path, "show", "HEAD:sample.txt"])
            #expect(blob.stdout == content)
            #expect(!FileManager.default.fileExists(atPath: repo.appendingPathComponent(".git/hooks").path))
            // Test setup never loads developer-defined aliases, even if an
            // individual call supplies a global config environment override.
            do {
                try await TestGitRepository.run(arguments: ["-C", repo.path, "fixture-alias"], environment: environment)
                Issue.record("Expected an unknown command, not a developer alias")
            } catch let error as GitError {
                #expect(error.exitCode == 1)
                #expect(error.stderr.contains("not a git command"))
            }
        }
    }

    @Test func clonedWorkingAndBareRepositoriesReceiveTheSameIsolation() async throws {
        try await TestGitRepository.withSharedRemote { remote, ours, theirs, _ in
            for repo in [remote, ours, theirs] {
                let result = try await TestGitRepository.run(arguments: ["-C", repo.path, "config", "--get", "core.hooksPath"])
                #expect(String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .newlines) == "/dev/null")
            }
        }
    }
}
