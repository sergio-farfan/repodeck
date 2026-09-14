import Foundation
import Testing
@testable import RepoDeckKit

/// `GitClient.configuredIdentity(in:)` against real, disposable git repos
/// (same temp-repo pattern as `GitClientIntegrationTests`), plus the pure
/// `GitIdentity.initials` derivation.
@Suite struct GitClientIdentityTests {
    /// Creates a unique temp git repo with a stable, non-interactive identity,
    /// runs `body` against it, then removes the temp dir unconditionally.
    private func withTempRepo(_ body: (URL, GitClient) async throws -> Void) async throws {
        try await TestGitRepository.withRepository(body)
    }

    /// The executable wrapper confines every --global operation to this
    /// fixture's file. It never changes the test process environment.
    private func isolatedClient(in repo: URL, beforeGit: String = "") throws -> (GitClient, URL) {
        let root = repo.deletingLastPathComponent()
        let global = root.appendingPathComponent("identity-global.config")
        let executable = root.appendingPathComponent("identity-git")
        let globalPath = "'" + global.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        try """
        #!/bin/sh
        export GIT_CONFIG_NOSYSTEM=1
        export GIT_CONFIG_GLOBAL=\(globalPath)
        export GIT_CONFIG_COUNT=0
        export GIT_CONFIG_PARAMETERS=
        unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE EMAIL
        \(beforeGit)
        exec /usr/bin/git "$@"

        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return (GitClient(gitPath: executable.path), global)
    }

    // MARK: configuredIdentity

    @Test func configuredIdentityReadsLocalNameAndEmail() async throws {
        try await withTempRepo { repo, client in
            let identity = try await client.configuredIdentity(in: repo)
            #expect(identity.name == "Test")
            #expect(identity.email == "test@example.com")
            #expect(identity.isConfigured)
        }
    }

    @Test func emptyStringEmailBecomesNilViaTrimming() async throws {
        try await withTempRepo { repo, client in
            // An explicitly empty value exits 0 with blank stdout — the trim
            // path (not the tolerated exit 1) is what maps it to nil.
            _ = try await TestGitRepository.run(arguments: ["-C", repo.path, "config", "user.email", ""])

            let identity = try await client.configuredIdentity(in: repo)
            #expect(identity.name == "Test")
            #expect(identity.email == nil)
        }
    }

    @Test func scopedIdentityReadsIncludesAndGlobalWritesPreserveRepositoryOverride() async throws {
        try await withTempRepo { repo, _ in
            let (client, global) = try isolatedClient(in: repo)
            #expect(try await client.configuredIdentity(in: repo, scope: .globalDefault) == GitIdentity(name: nil, email: nil))
            let included = repo.deletingLastPathComponent().appendingPathComponent("included-global.config")
            let includedBytes = Data("[user]\nname = Included Global\nemail = included@localhost\n".utf8)
            try includedBytes.write(to: included)
            try await TestGitRepository.run(arguments: ["config", "--file", global.path, "include.path", included.path])
            try await TestGitRepository.run(arguments: ["config", "--file", global.path, "alias.fixture", "status --short"])

            #expect(try await client.configuredIdentity(in: repo, scope: .globalDefault) == GitIdentity(name: "Included Global", email: "included@localhost"))
            // Repository fixture identity is itself in a local include.
            #expect(try await client.configuredIdentity(in: repo, scope: .repository) == GitIdentity(name: "Test", email: "test@example.com"))
            try await client.setConfiguredIdentity(name: "Global Default", email: "global@localhost", scope: .globalDefault, in: repo)

            #expect(try await client.configuredIdentity(in: repo, scope: .globalDefault) == GitIdentity(name: "Global Default", email: "global@localhost"))
            #expect(try await client.configuredIdentity(in: repo) == GitIdentity(name: "Test", email: "test@example.com"))
            #expect(try Data(contentsOf: included) == includedBytes)
            let alias = try await TestGitRepository.run(arguments: ["config", "--file", global.path, "alias.fixture"])
            #expect(String(decoding: alias.stdout, as: UTF8.self) == "status --short\n")
        }
    }

    @Test func repositoryIdentityPreservesLiteralTextAndReplacesDuplicateFields() async throws {
        try await withTempRepo { repo, _ in
            let (client, global) = try isolatedClient(in: repo)
            for key in ["user.name", "user.email"] {
                try await TestGitRepository.run(arguments: ["-C", repo.path, "config", "--local", "--add", key, "old one"])
                try await TestGitRepository.run(arguments: ["-C", repo.path, "config", "--local", "--add", key, "old two"])
            }
            try await TestGitRepository.run(arguments: ["-C", repo.path, "config", "--local", "remote.fixture.url", "ssh://example.invalid/group/project.git"])
            let name = "--Åda  O'\"Connor 开发者"
            let email = "d'ev+\"tag\"@localhost"
            try await client.setConfiguredIdentity(name: "  " + name + "  ", email: " " + email + " ", scope: .repository, in: repo)

            #expect(try await client.configuredIdentity(in: repo, scope: .repository) == GitIdentity(name: name, email: email))
            #expect(try await client.configuredIdentity(in: repo) == GitIdentity(name: name, email: email))
            for (key, expected) in [("user.name", name), ("user.email", email)] {
                let result = try await TestGitRepository.run(arguments: ["-C", repo.path, "config", "--local", "--get-all", key])
                #expect(String(decoding: result.stdout, as: UTF8.self) == expected + "\n")
            }
            let remote = try await TestGitRepository.run(arguments: ["-C", repo.path, "config", "remote.fixture.url"])
            #expect(String(decoding: remote.stdout, as: UTF8.self) == "ssh://example.invalid/group/project.git\n")
            #expect(!FileManager.default.fileExists(atPath: global.path))
        }
    }

    @Test func nonUTF8IdentityReadsFailWithoutChangingConfigurationBytes() async throws {
        try await withTempRepo { repo, _ in
            let (client, global) = try isolatedClient(in: repo)
            let config = repo.appendingPathComponent(".git/config")
            let invalidIdentity = Data("\n[user]\nname = Latin".utf8) + Data([0xff])
                + Data("\nemail = valid@localhost\n".utf8)
            let localBytes = try Data(contentsOf: config) + invalidIdentity
            try localBytes.write(to: config)
            try invalidIdentity.write(to: global)

            await #expect(throws: GitError.self) { try await client.configuredIdentity(in: repo) }
            for scope in GitIdentityScope.allCases {
                do {
                    _ = try await client.configuredIdentity(in: repo, scope: scope)
                    Issue.record("Expected a non-UTF-8 identity to be rejected")
                } catch let error as GitError {
                    #expect(error.stderr.contains("outside UTF-8"))
                }
            }
            #expect(try Data(contentsOf: config) == localBytes)
            #expect(try Data(contentsOf: global) == invalidIdentity)
        }
    }

    @Test func invalidIdentityDoesNotChangeEitherConfigurationScope() async throws {
        try await withTempRepo { repo, _ in
            let (client, global) = try isolatedClient(in: repo)
            let config = repo.appendingPathComponent(".git/config")
            let before = try Data(contentsOf: config)
            let invalid = [
                ("", "valid@localhost"), ("   ", "valid@localhost"), ("Valid", "  "),
                ("New Name", "two words@localhost"), ("Name\nInjected", "valid@localhost"),
                ("Name\u{2028}Injected", "valid@localhost"), ("Name\tInjected", "valid@localhost"),
                ("Name\0Injected", "valid@localhost"), ("Name\u{7f}", "valid@localhost"),
                ("<Name>", "valid@localhost"), ("Valid", "<mail@localhost>"), ("Valid", "mail\r@localhost"),
            ]
            for scope in GitIdentityScope.allCases {
                for (name, email) in invalid {
                    await #expect(throws: GitError.self) {
                        try await client.setConfiguredIdentity(name: name, email: email, scope: scope, in: repo)
                    }
                    #expect(try Data(contentsOf: config) == before)
                    #expect(!FileManager.default.fileExists(atPath: global.path))
                }
            }
        }
    }

    @Test func secondIdentityWriteFailureReportsPartialSaveAndOriginalDiagnostic() async throws {
        try await withTempRepo { repo, _ in
            let (client, _) = try isolatedClient(in: repo, beforeGit: """
            if [ "$3" = config ] && [ "$5" = --replace-all ] && [ "$6" = user.email ]; then
                printf '%s\\n' 'fixture email configuration is locked' >&2
                exit 73
            fi
            """)
            do {
                try await client.setConfiguredIdentity(name: "Saved Name", email: "new@localhost", scope: .repository, in: repo)
                Issue.record("Expected the second field write to fail")
            } catch let error as GitError {
                #expect(error.exitCode == 73)
                #expect(error.command.contains("user.email"))
                #expect(error.stderr.contains("may be partially saved"))
                #expect(error.stderr.contains("fixture email configuration is locked"))
            }
            #expect(try await client.configuredIdentity(in: repo, scope: .repository) == GitIdentity(name: "Saved Name", email: "test@example.com"))
        }
    }

    @Test func cancellationDuringSecondIdentityWriteReportsPartialSave() async throws {
        try await withTempRepo { repo, _ in
            let (client, _) = try isolatedClient(in: repo, beforeGit: """
            if [ "$3" = config ] && [ "$5" = --replace-all ] && [ "$6" = user.email ]; then
                touch "$2/.identity-email-started"
                sleep 30
            fi
            """)
            let marker = repo.appendingPathComponent(".identity-email-started")
            let completion = IdentityWriteCompletion()
            let task = Task {
                let result: Result<Void, Error>
                do {
                    try await client.setConfiguredIdentity(name: "Saved Before Cancellation", email: "new@localhost", scope: .repository, in: repo)
                    result = .success(())
                } catch { result = .failure(error) }
                await completion.finish()
                return result
            }
            let deadline = ContinuousClock.now + .seconds(30)
            while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < deadline {
                if await completion.finished { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let started = FileManager.default.fileExists(atPath: marker.path)
            task.cancel()
            let result = await task.value
            try #require(started, "Second write did not start: \(result)")
            switch result {
            case .success: Issue.record("Expected cancellation to interrupt the save")
            case .failure(let error):
                let error = try #require(error as? GitError)
                #expect(error.stderr.contains("may be partially saved"))
                #expect(error.stderr.contains("cancelled"))
            }
            #expect(try await client.configuredIdentity(in: repo, scope: .repository) == GitIdentity(name: "Saved Before Cancellation", email: "test@example.com"))
        }
    }

    // MARK: effectiveCommitAuthor

    @Test func authorConfigurationMatchesOrdinaryCommitAndDoesNotChangeEditableDefaults() async throws {
        try await withTempRepo { repo, _ in
            let (client, _) = try isolatedClient(in: repo)
            let expected = GitIdentity(name: "Åda  \"A\" O'Connor", email: "author@localhost")
            try await TestGitRepository.run(arguments: ["-C", repo.path, "config", "author.name", expected.name!])
            try await TestGitRepository.run(arguments: ["-C", repo.path, "config", "author.email", expected.email!])
            let file = repo.appendingPathComponent("authored.txt")
            let contents = Data("ordinary commit\n".utf8)
            try contents.write(to: file)
            try await client.stage(["authored.txt"], in: repo)
            let index = try Data(contentsOf: repo.appendingPathComponent(".git/index"))
            let config = try Data(contentsOf: repo.appendingPathComponent(".git/config"))
            let head = try Data(contentsOf: repo.appendingPathComponent(".git/HEAD"))

            #expect(try await client.effectiveCommitAuthor(in: repo) == expected)
            #expect(try await client.configuredIdentity(in: repo) == GitIdentity(name: "Test", email: "test@example.com"))
            #expect(try await client.configuredIdentity(in: repo, scope: .repository) == GitIdentity(name: "Test", email: "test@example.com"))
            #expect(try Data(contentsOf: repo.appendingPathComponent(".git/config")) == config)
            #expect(try Data(contentsOf: repo.appendingPathComponent(".git/index")) == index)
            #expect(try Data(contentsOf: repo.appendingPathComponent(".git/HEAD")) == head)
            #expect(try Data(contentsOf: file) == contents)

            try await client.commit(message: "Ordinary authored commit", in: repo)
            let actual = try await TestGitRepository.run(arguments: ["-C", repo.path, "log", "-1", "--format=%an%x00%ae"])
            #expect(actual.stdout == Data((expected.name! + "\0" + expected.email! + "\n").utf8))
        }
    }

    @Test func inheritedAuthorEnvironmentMatchesGitNormalizationAndActualCommit() async throws {
        try await withTempRepo { repo, _ in
            let (client, _) = try isolatedClient(in: repo, beforeGit: """
            export GIT_AUTHOR_NAME='  <Env>  Åda
            Second  '
            export GIT_AUTHOR_EMAIL='env <alias> @localhost'
            export GIT_AUTHOR_DATE='@1000000000 +0530'
            """)
            try await TestGitRepository.run(arguments: ["-C", repo.path, "config", "author.name", "Configured Author"])
            try await TestGitRepository.run(arguments: ["-C", repo.path, "config", "author.email", "configured@localhost"])
            let expected = GitIdentity(name: "Env  ÅdaSecond", email: "env alias @localhost")
            #expect(try await client.effectiveCommitAuthor(in: repo) == expected)
            #expect(try await client.configuredIdentity(in: repo) == GitIdentity(name: "Test", email: "test@example.com"))
            try Data("environment author\n".utf8).write(to: repo.appendingPathComponent("file.txt"))
            try await client.stage(["file.txt"], in: repo)
            try await client.commit(message: "Environment author", in: repo)
            let actual = try await TestGitRepository.run(arguments: ["-C", repo.path, "log", "-1", "--format=%an%x00%ae"])
            #expect(actual.stdout == Data((expected.name! + "\0" + expected.email! + "\n").utf8))
        }
    }

    @Test func explicitlyEmptyAuthorEmailIsPreservedWhenGitAcceptsIt() async throws {
        try await withTempRepo { repo, _ in
            let (client, _) = try isolatedClient(in: repo, beforeGit: "export GIT_AUTHOR_EMAIL=''")
            #expect(try await client.effectiveCommitAuthor(in: repo) == GitIdentity(name: "Test", email: ""))
            try Data("empty email\n".utf8).write(to: repo.appendingPathComponent("file.txt"))
            try await client.stage(["file.txt"], in: repo)
            try await client.commit(message: "Empty author email", in: repo)
            let actual = try await TestGitRepository.run(arguments: ["-C", repo.path, "log", "-1", "--format=%an%x00%ae"])
            #expect(actual.stdout == Data("Test\0\n".utf8))
        }
    }

    @Test func missingOrInvalidAuthorIsAnErrorWithoutConfigurationWrites() async throws {
        try await withTempRepo { repo, _ in
            let (client, _) = try isolatedClient(in: repo)
            let defaults = repo.appendingPathComponent(".git/repodeck-test-defaults.config")
            for key in ["user.name", "user.email"] {
                try await TestGitRepository.run(arguments: ["config", "--file", defaults.path, "--unset-all", key])
            }
            try await TestGitRepository.run(arguments: ["-C", repo.path, "config", "user.useConfigOnly", "true"])
            let configURL = repo.appendingPathComponent(".git/config")
            let before = try Data(contentsOf: configURL)
            let includedBefore = try Data(contentsOf: defaults)
            #expect(try await client.configuredIdentity(in: repo) == GitIdentity(name: nil, email: nil))
            do {
                _ = try await client.effectiveCommitAuthor(in: repo)
                Issue.record("Missing required identity must remain an error")
            } catch let error as GitError {
                #expect(error.exitCode != 0)
                #expect(error.command.contains("var GIT_AUTHOR_IDENT"))
                #expect(!error.stderr.isEmpty)
            }
            #expect(try Data(contentsOf: configURL) == before)
            #expect(try Data(contentsOf: defaults) == includedBefore)

            try await TestGitRepository.run(arguments: ["-C", repo.path, "config", "user.name", ""])
            try await TestGitRepository.run(arguments: ["-C", repo.path, "config", "user.email", "valid@localhost"])
            let invalidBefore = try Data(contentsOf: configURL)
            await #expect(throws: GitError.self) { try await client.effectiveCommitAuthor(in: repo) }
            #expect(try Data(contentsOf: configURL) == invalidBefore)
        }
    }

    @Test func nonUTF8AndOversizedAuthorOutputCannotBecomeAnIdentity() async throws {
        try await withTempRepo { repo, _ in
            let (client, _) = try isolatedClient(in: repo)
            let config = repo.appendingPathComponent(".git/config")
            let original = try Data(contentsOf: config)
            let invalid = original + Data("\n[author]\nname = Latin".utf8) + Data([0xff])
                + Data("\nemail = author@localhost\n".utf8)
            try invalid.write(to: config)
            do {
                _ = try await client.effectiveCommitAuthor(in: repo)
                Issue.record("Non-UTF-8 author output must be rejected")
            } catch let error as GitError { #expect(error.stderr.contains("outside UTF-8")) }
            #expect(try Data(contentsOf: config) == invalid)

            try original.write(to: config)
            try await TestGitRepository.run(arguments: ["-C", repo.path, "config", "author.name", String(repeating: "x", count: 70_000)])
            let oversized = try Data(contentsOf: config)
            do {
                _ = try await client.effectiveCommitAuthor(in: repo)
                Issue.record("Truncated author output must be rejected")
            } catch let error as GitError { #expect(error.stderr.contains("64 KiB limit")) }
            #expect(try Data(contentsOf: config) == oversized)
        }
    }

    @Test func malformedAuthorFramingIsRejectedInsteadOfGuessingFields() async throws {
        try await withTempRepo { repo, _ in
            for output in ["Name <email> not-a-date +0000\n", "Name <email> 123 UTC\n", "Name <email> 123 +0000\nextra\n", "Name <email> 123 +0000"] {
                let quoted = "'" + output.replacingOccurrences(of: "'", with: "'\\''") + "'"
                let (client, _) = try isolatedClient(in: repo, beforeGit: """
                if [ "$3" = var ]; then
                    printf '%s' \(quoted)
                    exit 0
                fi
                """)
                do {
                    _ = try await client.effectiveCommitAuthor(in: repo)
                    Issue.record("Malformed author output must be rejected")
                } catch let error as GitError { #expect(error.stderr.contains("unexpected author identity format")) }
            }
        }
    }

    // MARK: GitIdentity.initials

    @Test func initialsTakeFirstAndLastWordOfName() {
        #expect(GitIdentity(name: "Ada Lovelace", email: nil).initials == "AL")
    }

    @Test func initialsForSingleWordNameAreOneLetter() {
        #expect(GitIdentity(name: "Prince", email: nil).initials == "P")
    }

    @Test func initialsFallBackToFirstLetterOfEmail() {
        #expect(GitIdentity(name: nil, email: "sergio@x.com").initials == "S")
    }

    @Test func initialsAreNilWhenNothingIsConfigured() {
        let identity = GitIdentity(name: nil, email: nil)
        #expect(identity.initials == nil)
        #expect(!identity.isConfigured)
    }

    @Test func completeIdentityRequiresBothNonblankFields() {
        #expect(GitIdentity(name: "Name", email: "mail@localhost").isComplete)
        #expect(!GitIdentity(name: "Name", email: nil).isComplete)
        #expect(!GitIdentity(name: "Name", email: " \n ").isComplete)
        #expect(!GitIdentity(name: " \n ", email: "mail@localhost").isComplete)
        #expect(GitIdentity(name: "Name", email: nil).isConfigured)
    }
}

private actor IdentityWriteCompletion {
    private(set) var finished = false
    func finish() { finished = true }
}
