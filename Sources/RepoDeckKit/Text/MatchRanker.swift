import Foundation

/// Ranks how well a query matches a candidate string for palette-style
/// filtering. Lower is better; `nil` means no match. Deliberately simple —
/// prefix, word-boundary, substring — not fuzzy-subsequence.
public enum MatchRanker {
    /// - 0: candidate begins with query
    /// - 1: any word in candidate begins with query (word boundaries:
    ///      whitespace, "-", "_", "." and lowercase→uppercase transitions,
    ///      e.g. "Deck" matches word-start in "RepoDeck")
    /// - 2: candidate contains query anywhere else
    /// - nil: no match
    /// Matching is case-insensitive; query is trimmed. An empty (or
    /// whitespace-only) query returns 0 for every candidate — the palette
    /// shows its default list unranked.
    public static func rank(_ query: String, in candidate: String) -> Int? {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return 0 }

        let lowerQuery = trimmedQuery.lowercased()
        let lowerCandidate = candidate.lowercased()

        if lowerCandidate.hasPrefix(lowerQuery) {
            return 0
        }

        for start in wordStartIndices(in: candidate) {
            let remainder = candidate[start...].lowercased()
            if remainder.hasPrefix(lowerQuery) {
                return 1
            }
        }

        if lowerCandidate.contains(lowerQuery) {
            return 2
        }

        return nil
    }

    /// Word-start indices in the ORIGINAL candidate string: the first
    /// character, any character immediately following a separator
    /// (whitespace, "-", "_", "."), and any uppercase character whose
    /// predecessor is not uppercase (camelCase boundary).
    private static func wordStartIndices(in candidate: String) -> [String.Index] {
        var indices: [String.Index] = []
        var previousCharacter: Character?

        for index in candidate.indices {
            let character = candidate[index]
            defer { previousCharacter = character }

            guard let previous = previousCharacter else {
                indices.append(index)
                continue
            }

            if isSeparator(previous) && !isSeparator(character) {
                indices.append(index)
            } else if character.isUppercase && !previous.isUppercase {
                indices.append(index)
            }
        }

        return indices
    }

    private static func isSeparator(_ character: Character) -> Bool {
        character.isWhitespace || character == "-" || character == "_" || character == "."
    }
}
