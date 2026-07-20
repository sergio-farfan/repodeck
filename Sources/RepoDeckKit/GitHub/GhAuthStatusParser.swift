import Foundation

/// Extracts the active account login from `gh auth status` human-readable
/// output. Pure function: no `Process`, no I/O — mirrors `GhJSONParser`'s
/// role for `gh pr list`, but over gh's unversioned status prose instead of
/// JSON (`gh auth status` has no `--json` flag as of gh 2.x).
public enum GhAuthStatusParser {
    /// Returns the active account login, or nil on anything unrecognized
    /// (not logged in, future format change, garbage). Handles both known
    /// formats:
    ///
    ///   old:  "✓ Logged in to github.com as monalisa (oauth_token)"
    ///   new:  "✓ Logged in to github.com account monalisa (keyring)"
    ///         with "  - Active account: true" on a following line
    ///         (gh >= 2.40 multi-account output)
    ///
    /// Rule: scan lines for `Logged in to <host> as <login>` or `Logged in
    /// to <host> account <login>`, stripping a trailing parenthesized token.
    /// In multi-account output the login whose following lines (before the
    /// next "Logged in" line) contain `Active account: true` wins; otherwise
    /// the first match does.
    public static func activeLogin(from output: String) -> String? {
        var accounts: [(login: String, isActive: Bool)] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            if let login = login(fromLoggedInLine: line) {
                accounts.append((login: login, isActive: false))
            } else if !accounts.isEmpty, line.contains("Active account: true") {
                accounts[accounts.count - 1].isActive = true
            }
        }
        return (accounts.first(where: \.isActive) ?? accounts.first)?.login
    }

    /// Parses one line of the form `... Logged in to <host> as <login> ...`
    /// or `... Logged in to <host> account <login> ...`; nil for any other
    /// line. A trailing parenthesized token — `(oauth_token)`, `(keyring)` —
    /// is a separate whitespace-delimited token, but a login glued to an
    /// open paren is also tolerated by cutting at the first `(`.
    private static func login(fromLoggedInLine line: Substring) -> String? {
        guard let marker = line.range(of: "Logged in to ") else { return nil }
        let tokens = line[marker.upperBound...].split(whereSeparator: \.isWhitespace)
        guard tokens.count >= 3, tokens[1] == "as" || tokens[1] == "account" else { return nil }
        let login = tokens[2].prefix { $0 != "(" }
        return login.isEmpty ? nil : String(login)
    }
}
