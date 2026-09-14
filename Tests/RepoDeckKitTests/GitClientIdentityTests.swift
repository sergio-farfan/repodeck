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
}
