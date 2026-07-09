import Foundation
import Testing
@testable import RepoDeckKit

/// Integration tests for `GitClient.searchLog`, one per `HistorySearchField`
/// axis, against a temp repo with three commits deliberately shaped so each
/// axis discriminates differently:
///
///   A: "add login"          — author Alice <a@x> — touches auth.swift (adds `let token = 1`)
///   B: "fix logout bug"     — author Bob   <b@x> — touches ui.swift
///   C: "update login docs"  — author Alice <a@x> — touches README.md
@Suite struct GitClientSearchTests {
    /// Creates a unique temp git repo with a stable, non-interactive identity
    /// and the three fixture commits above, then hands it to `body`. Mirrors
    /// `GitClientIntegrationTests.withTempRepo`, but commits per-author via
    /// `git commit --author` rather than the shared default identity.
    private func withSearchFixtureRepo(_ body: (URL, GitClient) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("repodeck-search-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try await ProcessRunner.run(arguments: ["init", "-b", "main"], workingDirectory: root)
        _ = try await ProcessRunner.run(arguments: ["-C", root.path, "config", "user.email", "test@example.com"])
        _ = try await ProcessRunner.run(arguments: ["-C", root.path, "config", "user.name", "Test"])
        _ = try await ProcessRunner.run(arguments: ["-C", root.path, "config", "commit.gpgsign", "false"])

        let client = GitClient()

        // Commit A: "add login", author Alice, touches auth.swift.
        try "let token = 1".write(
            to: root.appendingPathComponent("auth.swift"),
            atomically: true,
            encoding: .utf8
        )
        try await client.stage(["auth.swift"], in: root)
        _ = try await ProcessRunner.run(arguments: [
            "-C", root.path, "commit",
            "--author=Alice <a@x>",
            "-m", "add login",
        ])

        // Commit B: "fix logout bug", author Bob, touches ui.swift.
        try "class UI {}".write(
            to: root.appendingPathComponent("ui.swift"),
            atomically: true,
            encoding: .utf8
        )
        try await client.stage(["ui.swift"], in: root)
        _ = try await ProcessRunner.run(arguments: [
            "-C", root.path, "commit",
            "--author=Bob <b@x>",
            "-m", "fix logout bug",
        ])

        // Commit C: "update login docs", author Alice, touches README.md.
        try "# Login docs".write(
            to: root.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        try await client.stage(["README.md"], in: root)
        _ = try await ProcessRunner.run(arguments: [
            "-C", root.path, "commit",
            "--author=Alice <a@x>",
            "-m", "update login docs",
        ])

        try await body(root, client)
    }

    // MARK: - .message

    @Test func messageSearchMatchesSubsetBySubject() async throws {
        try await withSearchFixtureRepo { repo, client in
            let query = HistorySearchQuery(text: "login", field: .message)
            let commits = try await client.searchLog(query, in: repo)
            #expect(Set(commits.map(\.subject)) == ["add login", "update login docs"])
        }
    }

    // MARK: - .author

    @Test func authorSearchMatchesSubsetByAuthor() async throws {
        try await withSearchFixtureRepo { repo, client in
            let query = HistorySearchQuery(text: "Bob", field: .author)
            let commits = try await client.searchLog(query, in: repo)
            #expect(commits.map(\.subject) == ["fix logout bug"])
        }
    }

    // MARK: - .path

    @Test func pathSearchMatchesSubsetByTouchedFile() async throws {
        try await withSearchFixtureRepo { repo, client in
            let query = HistorySearchQuery(text: "auth.swift", field: .path)
            let commits = try await client.searchLog(query, in: repo)
            #expect(commits.map(\.subject) == ["add login"])
        }
    }

    // MARK: - .content (pickaxe)

    @Test func contentSearchMatchesSubsetByAddedLine() async throws {
        try await withSearchFixtureRepo { repo, client in
            let query = HistorySearchQuery(text: "token", field: .content)
            let commits = try await client.searchLog(query, in: repo)
            #expect(commits.map(\.subject) == ["add login"])
        }
    }

    // MARK: - empty query falls back to full log

    @Test func emptyQueryTextReturnsFullLog() async throws {
        try await withSearchFixtureRepo { repo, client in
            let query = HistorySearchQuery(text: "   ", field: .message)
            let commits = try await client.searchLog(query, in: repo)
            #expect(commits.count == 3)
        }
    }

    // MARK: - fresh repo, no commits (exit-128 path)

    @Test func searchOnFreshRepoWithNoCommitsReturnsEmpty() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("repodeck-search-fresh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try await ProcessRunner.run(arguments: ["init", "-b", "main"], workingDirectory: root)
        _ = try await ProcessRunner.run(arguments: ["-C", root.path, "config", "user.email", "test@example.com"])
        _ = try await ProcessRunner.run(arguments: ["-C", root.path, "config", "user.name", "Test"])

        let client = GitClient()
        let query = HistorySearchQuery(text: "login", field: .message)
        let commits = try await client.searchLog(query, in: root)
        #expect(commits.isEmpty)
    }
}
