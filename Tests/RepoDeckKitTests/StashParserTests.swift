import Foundation
import Testing
@testable import RepoDeckKit

private let unitSeparator: Character = "\u{1f}"
private let recordSeparator: Character = "\u{0}"

/// Builds one `git stash list` record in the format produced by
/// `-z --format=%gd%x1f%gs%x1f%cI`.
private func record(selector: String, subject: String, date: String) -> String {
    "\(selector)\(unitSeparator)\(subject)\(unitSeparator)\(date)\(recordSeparator)"
}

private func iso8601Date(_ string: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: string)
}

@Test func emptyInputProducesNoStashes() {
    #expect(StashParser.parse("").isEmpty)
}

@Test func singleEntryParsesIndexSubjectAndDate() {
    let output = record(
        selector: "stash@{0}",
        subject: "WIP on main: 1a2b3c msg",
        date: "2026-07-14T11:22:33-05:00"
    )

    let stashes = StashParser.parse(output)

    #expect(stashes.count == 1)
    #expect(stashes[0].index == 0)
    #expect(stashes[0].subject == "WIP on main: 1a2b3c msg")
    #expect(stashes[0].date == iso8601Date("2026-07-14T11:22:33-05:00"))
}

@Test func multipleEntriesParseInOrderWithDistinctIndices() {
    let output = record(selector: "stash@{0}", subject: "third", date: "2026-07-14T09:00:00+00:00")
        + record(selector: "stash@{1}", subject: "second", date: "2026-07-13T09:00:00+00:00")
        + record(selector: "stash@{2}", subject: "first", date: "2026-07-12T09:00:00+00:00")

    let stashes = StashParser.parse(output)

    #expect(stashes.count == 3)
    #expect(stashes.map(\.index) == [0, 1, 2])
    #expect(stashes.map(\.subject) == ["third", "second", "first"])
}

@Test func subjectContainingColonsAndSpacesPreservedVerbatim() {
    let subject = "On main: fix: handle edge-case (again): re-stash"
    let output = record(selector: "stash@{0}", subject: subject, date: "2026-07-14T09:00:00+00:00")

    let stashes = StashParser.parse(output)

    #expect(stashes.count == 1)
    #expect(stashes[0].subject == subject)
}

@Test func unparseableDateProducesNilDateButEntryKept() {
    let output = record(selector: "stash@{0}", subject: "WIP on main: msg", date: "not-a-date")

    let stashes = StashParser.parse(output)

    #expect(stashes.count == 1)
    #expect(stashes[0].date == nil)
    #expect(stashes[0].subject == "WIP on main: msg")
}

@Test func malformedSelectorRecordIsSkipped() {
    let good = record(selector: "stash@{0}", subject: "kept", date: "2026-07-14T09:00:00+00:00")
    let bad = record(selector: "not-a-selector", subject: "dropped", date: "2026-07-14T09:00:00+00:00")

    let stashes = StashParser.parse(good + bad)

    #expect(stashes.count == 1)
    #expect(stashes[0].subject == "kept")
}

@Test func trailingNulProducesNoPhantomStash() {
    let single = record(selector: "stash@{0}", subject: "only", date: "2026-07-14T09:00:00+00:00")
    // `record` already appends the NUL record separator; git's actual `-z`
    // output also ends with exactly one trailing NUL and no extra newline.
    let stashes = StashParser.parse(single)

    #expect(stashes.count == 1)
}
