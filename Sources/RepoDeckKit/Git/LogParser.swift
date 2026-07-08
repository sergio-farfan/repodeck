import Foundation

/// Parses the output of
/// `git log --pretty=format:%H%x1f%h%x1f%s%x1f%an%x1f%aI%x1f%D%x1e`
/// into `Commit` values. Pure function: no `Process`, no I/O.
public enum LogParser {
    private static let recordSeparator: Character = "\u{1e}"
    private static let fieldSeparator = "\u{1f}"
    private static let expectedFieldCount = 6

    public static func parse(_ output: String) -> [Commit] {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime]

        return output
            .split(separator: recordSeparator, omittingEmptySubsequences: true)
            .compactMap { rawRecord -> Commit? in
                let trimmed = rawRecord.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }

                let fields = trimmed.components(separatedBy: fieldSeparator)
                guard fields.count == expectedFieldCount else { return nil }

                guard let date = dateFormatter.date(from: fields[4]) else { return nil }

                let refsField = fields[5]
                let refs = refsField.isEmpty ? [] : refsField.components(separatedBy: ", ")

                return Commit(
                    hash: fields[0],
                    shortHash: fields[1],
                    subject: fields[2],
                    author: fields[3],
                    date: date,
                    refs: refs
                )
            }
    }
}
