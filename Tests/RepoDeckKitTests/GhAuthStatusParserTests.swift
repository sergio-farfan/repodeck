import Foundation
import Testing
@testable import RepoDeckKit

/// Fixtures below mirror real `gh auth status` output shapes: the old
/// single-account `as <login> (oauth_token)` prose, the gh >= 2.40
/// `account <login> (keyring)` form with per-account `Active account:`
/// lines, and the not-logged-in message.

@Test func oldSingleAccountAsFormatParsesLogin() {
    let output = """
    github.com
      ✓ Logged in to github.com as monalisa (oauth_token)
      ✓ Git operations for github.com configured to use https protocol.
      ✓ Token: gho_************************************
    """

    #expect(GhAuthStatusParser.activeLogin(from: output) == "monalisa")
}

@Test func newAccountKeyringFormatParsesLogin() {
    let output = """
    github.com
      ✓ Logged in to github.com account monalisa (keyring)
      - Active account: true
      - Git operations protocol: https
      - Token: gho_************************************
    """

    #expect(GhAuthStatusParser.activeLogin(from: output) == "monalisa")
}

@Test func multiAccountOutputPrefersTheActiveAccount() {
    // gh >= 2.40 multi-account: the first listed account is NOT active —
    // the parser must pick the one whose block says `Active account: true`,
    // not just the first "Logged in" line.
    let output = """
    github.com
      ✓ Logged in to github.com account octocat (keyring)
      - Active account: false
      - Git operations protocol: https
      - Token: gho_************************************

      ✓ Logged in to github.com account monalisa (keyring)
      - Active account: true
      - Git operations protocol: https
      - Token: gho_************************************
    """

    #expect(GhAuthStatusParser.activeLogin(from: output) == "monalisa")
}

@Test func notLoggedInOutputReturnsNil() {
    let output = "You are not logged into any GitHub hosts. To log in, run: gh auth login"

    #expect(GhAuthStatusParser.activeLogin(from: output) == nil)
}

@Test func garbageOutputReturnsNil() {
    #expect(GhAuthStatusParser.activeLogin(from: "complete nonsense\nno status here\n") == nil)
    #expect(GhAuthStatusParser.activeLogin(from: "") == nil)
}
