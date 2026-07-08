import Foundation
import Testing
@testable import RepoDeckKit

private let unitSeparator: Character = "\u{1f}"
private let recordSeparator: Character = "\u{1e}"

/// Builds one `git log` record in the format produced by
/// `--pretty=format:%H%x1f%h%x1f%s%x1f%an%x1f%aI%x1f%D%x1e`.
private func record(
    hash: String,
    shortHash: String,
    subject: String,
    author: String,
    date: String,
    refs: String
) -> String {
    "\(hash)\(unitSeparator)\(shortHash)\(unitSeparator)\(subject)\(unitSeparator)\(author)\(unitSeparator)\(date)\(unitSeparator)\(refs)\(recordSeparator)"
}

private func iso8601Date(_ string: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: string)
}

@Test func parsesTwoCommitsFirstDecoratedSecondUndecorated() {
    let output = record(
        hash: "abc123fullhash",
        shortHash: "abc123",
        subject: "Add feature",
        author: "Sergio Farfan",
        date: "2026-07-08T11:22:33-05:00",
        refs: "HEAD -> main, origin/main"
    ) + record(
        hash: "def456fullhash",
        shortHash: "def456",
        subject: "Fix bug",
        author: "Jane Doe",
        date: "2026-07-01T09:00:00+00:00",
        refs: ""
    )

    let commits = LogParser.parse(output)

    #expect(commits.count == 2)

    #expect(commits[0].hash == "abc123fullhash")
    #expect(commits[0].shortHash == "abc123")
    #expect(commits[0].subject == "Add feature")
    #expect(commits[0].author == "Sergio Farfan")
    #expect(commits[0].date == iso8601Date("2026-07-08T11:22:33-05:00"))
    #expect(commits[0].refs == ["HEAD -> main", "origin/main"])

    #expect(commits[1].hash == "def456fullhash")
    #expect(commits[1].shortHash == "def456")
    #expect(commits[1].subject == "Fix bug")
    #expect(commits[1].author == "Jane Doe")
    #expect(commits[1].date == iso8601Date("2026-07-01T09:00:00+00:00"))
    #expect(commits[1].refs == [])
}

@Test func emptyRefsFieldProducesEmptyArray() {
    let output = record(
        hash: "h1",
        shortHash: "h1s",
        subject: "subject",
        author: "author",
        date: "2026-01-01T00:00:00+00:00",
        refs: ""
    )

    let commits = LogParser.parse(output)

    #expect(commits.count == 1)
    #expect(commits[0].refs == [])
}

@Test func emptyInputProducesNoCommits() {
    #expect(LogParser.parse("").isEmpty)
}

@Test func subjectWithSpecialCharactersPreservedVerbatim() {
    let subject = #"Fix "quoted" bug: handle edge-case (again)!"#
    let output = record(
        hash: "h1",
        shortHash: "h1s",
        subject: subject,
        author: "author",
        date: "2026-01-01T00:00:00+00:00",
        refs: ""
    )

    let commits = LogParser.parse(output)

    #expect(commits.count == 1)
    #expect(commits[0].subject == subject)
}

@Test func dateIsParsedFromISO8601WithTimezoneOffset() {
    let dateString = "2026-07-08T11:22:33-05:00"
    let output = record(
        hash: "h1",
        shortHash: "h1s",
        subject: "subject",
        author: "author",
        date: dateString,
        refs: ""
    )

    let commits = LogParser.parse(output)
    let expected = iso8601Date(dateString)

    #expect(expected != nil)
    #expect(commits.count == 1)
    #expect(commits[0].date == expected)
}

@Test func trailingRecordSeparatorProducesNoPhantomCommit() {
    let single = record(
        hash: "h1",
        shortHash: "h1s",
        subject: "subject",
        author: "author",
        date: "2026-01-01T00:00:00+00:00",
        refs: ""
    )
    // `record` already appends the record separator; simulate the extra
    // trailing newline that `git log` output typically has as well.
    let output = single + "\n"

    let commits = LogParser.parse(output)

    #expect(commits.count == 1)
}
