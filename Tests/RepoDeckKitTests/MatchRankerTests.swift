import Foundation
import Testing
@testable import RepoDeckKit

@Test("1. Prefix match is case-insensitive")
func prefixMatchIsCaseInsensitive() {
    #expect(MatchRanker.rank("repo", in: "RepoDeck") == 0)
}

@Test("2. Word boundary — separator characters")
func wordBoundarySeparatorCharacters() {
    #expect(MatchRanker.rank("deck", in: "repo-deck") == 1)
    #expect(MatchRanker.rank("lib", in: "git_lib") == 1)
    #expect(MatchRanker.rank("swift", in: "my.swift.tools") == 1)
}

@Test("3. Word boundary — camelCase transition")
func wordBoundaryCamelCaseTransition() {
    #expect(MatchRanker.rank("deck", in: "RepoDeck") == 1)
}

@Test("4. Substring match anywhere else")
func substringMatchAnywhereElse() {
    #expect(MatchRanker.rank("epod", in: "RepoDeck") == 2)
}

@Test("5. No match returns nil")
func noMatchReturnsNil() {
    #expect(MatchRanker.rank("xyz", in: "RepoDeck") == nil)
}

@Test("6. Empty or whitespace-only query ranks everything 0")
func emptyOrWhitespaceQueryRanksZero() {
    #expect(MatchRanker.rank("", in: "anything") == 0)
    #expect(MatchRanker.rank("  ", in: "anything") == 0)
}

@Test("7. Prefix wins over a later word boundary")
func prefixWinsOverLaterWordBoundary() {
    #expect(MatchRanker.rank("re", in: "repo-restore") == 0)
}

@Test("8. Unicode sanity")
func unicodeSanity() {
    #expect(MatchRanker.rank("ü", in: "über-repo") == 0)
}
