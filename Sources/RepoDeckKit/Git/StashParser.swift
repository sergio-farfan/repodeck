import Foundation

/// Parses the output of
/// `git stash list -z --format=%gd%x1f%gs%x1f%cI`
/// into `StashEntry` values. Pure function: no `Process`, no I/O.
///
/// Unlike `LogParser`'s `git log` (which self-terminates records with
/// `%x1e`), `git stash list -z` uses `-z` for NUL-terminated RECORDS —
/// fields within a record are still `%x1f`-separated. The first field is a
/// `stash@{N}` selector (`%gd`); `N` is extracted as `StashEntry.index`. A
/// record whose selector doesn't match that shape is skipped
/// (forward-compatible with any future selector format).
public enum StashParser {
    private static let recordSeparator: Character = "\u{0}"
    private static let fieldSeparator = "\u{1f}"
    private static let expectedFieldCount = 3

    public static func parse(_ output: String) -> [StashEntry] {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime]

        return output
            .split(separator: recordSeparator, omittingEmptySubsequences: true)
            .compactMap { rawRecord -> StashEntry? in
                let trimmed = rawRecord.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }

                let fields = trimmed.components(separatedBy: fieldSeparator)
                guard fields.count == expectedFieldCount else { return nil }

                guard let index = index(fromSelector: fields[0]) else { return nil }

                return StashEntry(
                    index: index,
                    subject: fields[1],
                    date: dateFormatter.date(from: fields[2])
                )
            }
    }

    /// Extracts `N` from a `stash@{N}` selector (`%gd`); `nil` if the
    /// selector isn't shaped that way.
    private static func index(fromSelector selector: String) -> Int? {
        guard selector.hasPrefix("stash@{"), selector.hasSuffix("}") else { return nil }
        let inner = selector.dropFirst("stash@{".count).dropLast()
        return Int(inner)
    }
}
