import Foundation
import Testing
@testable import RepoDeckKit

/// Joins `lines` with "\n" and appends a final trailing "\n", matching how
/// real `git diff`/`git show` output is terminated.
private func fixture(_ lines: String...) -> String {
    lines.joined(separator: "\n") + "\n"
}

@Test func emptyInputProducesNoFileDiffs() {
    #expect(DiffParser.parse("").isEmpty)
}

@Test func unknownLeadingLineIsSkipped() {
    // e.g. the commit-message preamble `git show` emits without `--format=`.
    let output = fixture(
        "commit abc123",
        "Author: Test <test@example.com>",
        "",
        "    some commit message",
        "",
        "diff --git a/f.txt b/f.txt",
        "index aaa..bbb 100644",
        "--- a/f.txt",
        "+++ b/f.txt",
        "@@ -1 +1 @@",
        "-old",
        "+new"
    )

    let diffs = DiffParser.parse(output)

    #expect(diffs.count == 1)
    #expect(diffs[0].oldPath == "f.txt")
    #expect(diffs[0].newPath == "f.txt")
}

@Test func singleHunkAddRemoveContextMixNumbersLinesCorrectly() {
    let output = fixture(
        "diff --git a/f.txt b/f.txt",
        "index 83db48f..0682d7d 100644",
        "--- a/f.txt",
        "+++ b/f.txt",
        "@@ -1,3 +1,4 @@",
        " line1",
        "-line2",
        "+changed2",
        " line3",
        "+line4"
    )

    let diffs = DiffParser.parse(output)

    #expect(diffs.count == 1)
    let diff = diffs[0]
    #expect(diff.oldPath == "f.txt")
    #expect(diff.newPath == "f.txt")
    #expect(diff.isBinary == false)
    #expect(diff.hunks.count == 1)

    let hunk = diff.hunks[0]
    #expect(hunk.oldStart == 1)
    #expect(hunk.oldCount == 3)
    #expect(hunk.newStart == 1)
    #expect(hunk.newCount == 4)
    #expect(hunk.header == "@@ -1,3 +1,4 @@")

    #expect(hunk.lines == [
        DiffLine(kind: .context, text: "line1", oldLine: 1, newLine: 1),
        DiffLine(kind: .deletion, text: "line2", oldLine: 2, newLine: nil),
        DiffLine(kind: .addition, text: "changed2", oldLine: nil, newLine: 2),
        DiffLine(kind: .context, text: "line3", oldLine: 3, newLine: 3),
        DiffLine(kind: .addition, text: "line4", oldLine: nil, newLine: 4),
    ])
}

@Test func multiHunkFileKeepsVerbatimHeaderAndIndependentNumbering() {
    let output = fixture(
        "diff --git a/a.txt b/a.txt",
        "index 111..222 100644",
        "--- a/a.txt",
        "+++ b/a.txt",
        "@@ -1,3 +1,3 @@",
        " l1",
        "-l2",
        "+L2",
        " l3",
        "@@ -10,3 +10,3 @@ some context",
        " l10",
        "-l11",
        "+L11",
        " l12"
    )

    let diffs = DiffParser.parse(output)

    #expect(diffs.count == 1)
    #expect(diffs[0].hunks.count == 2)

    let first = diffs[0].hunks[0]
    #expect(first.oldStart == 1 && first.newStart == 1)
    #expect(first.lines.map(\.text) == ["l1", "l2", "L2", "l3"])

    let second = diffs[0].hunks[1]
    #expect(second.header == "@@ -10,3 +10,3 @@ some context")
    #expect(second.oldStart == 10)
    #expect(second.newStart == 10)
    #expect(second.lines == [
        DiffLine(kind: .context, text: "l10", oldLine: 10, newLine: 10),
        DiffLine(kind: .deletion, text: "l11", oldLine: 11, newLine: nil),
        DiffLine(kind: .addition, text: "L11", oldLine: nil, newLine: 11),
        DiffLine(kind: .context, text: "l12", oldLine: 12, newLine: 12),
    ])
}

@Test func multiFileDiffProducesOneFileDiffPerFileInOrder() {
    let output = fixture(
        "diff --git a/a.txt b/a.txt",
        "index 111..222 100644",
        "--- a/a.txt",
        "+++ b/a.txt",
        "@@ -1,1 +1,1 @@",
        "-a-old",
        "+a-new",
        "diff --git a/b.txt b/b.txt",
        "index 333..444 100644",
        "--- a/b.txt",
        "+++ b/b.txt",
        "@@ -1,1 +1,1 @@",
        "-b-old",
        "+b-new"
    )

    let diffs = DiffParser.parse(output)

    #expect(diffs.count == 2)
    #expect(diffs[0].oldPath == "a.txt")
    #expect(diffs[1].oldPath == "b.txt")
    #expect(diffs[0].hunks[0].lines.map(\.text) == ["a-old", "a-new"])
    #expect(diffs[1].hunks[0].lines.map(\.text) == ["b-old", "b-new"])
}

@Test func newFileDiffHasDevNullOldPathAndNumbersNewLinesFromOne() {
    let output = fixture(
        "diff --git a/new.txt b/new.txt",
        "new file mode 100644",
        "index 0000000..be92a90",
        "--- /dev/null",
        "+++ b/new.txt",
        "@@ -0,0 +1,2 @@",
        "+newA",
        "+newB"
    )

    let diffs = DiffParser.parse(output)

    #expect(diffs.count == 1)
    let diff = diffs[0]
    #expect(diff.oldPath == "/dev/null")
    #expect(diff.newPath == "new.txt")
    #expect(diff.displayPath == "new.txt")
    #expect(diff.hunks[0].oldStart == 0 && diff.hunks[0].oldCount == 0)
    #expect(diff.hunks[0].newStart == 1 && diff.hunks[0].newCount == 2)
    #expect(diff.hunks[0].lines == [
        DiffLine(kind: .addition, text: "newA", oldLine: nil, newLine: 1),
        DiffLine(kind: .addition, text: "newB", oldLine: nil, newLine: 2),
    ])
}

@Test func deletionDiffHasDevNullNewPathAndDisplayPathFallsBackToOldPath() {
    let output = fixture(
        "diff --git a/f.txt b/f.txt",
        "deleted file mode 100644",
        "index 83db48f..0000000",
        "--- a/f.txt",
        "+++ /dev/null",
        "@@ -1,3 +0,0 @@",
        "-line1",
        "-line2",
        "-line3"
    )

    let diffs = DiffParser.parse(output)

    #expect(diffs.count == 1)
    let diff = diffs[0]
    #expect(diff.oldPath == "f.txt")
    #expect(diff.newPath == "/dev/null")
    #expect(diff.displayPath == "f.txt")
    #expect(diff.hunks[0].lines == [
        DiffLine(kind: .deletion, text: "line1", oldLine: 1, newLine: nil),
        DiffLine(kind: .deletion, text: "line2", oldLine: 2, newLine: nil),
        DiffLine(kind: .deletion, text: "line3", oldLine: 3, newLine: nil),
    ])
}

@Test func pureRenameHasNoHunksAndPathsComeFromDiffGitLine() {
    let output = fixture(
        "diff --git a/orig.txt b/renamed.txt",
        "similarity index 100%",
        "rename from orig.txt",
        "rename to renamed.txt"
    )

    let diffs = DiffParser.parse(output)

    #expect(diffs.count == 1)
    let diff = diffs[0]
    #expect(diff.oldPath == "orig.txt")
    #expect(diff.newPath == "renamed.txt")
    #expect(diff.hunks.isEmpty)
    #expect(diff.isBinary == false)
}

@Test func binaryFileDiffSetsIsBinaryWithNoHunks() {
    let output = fixture(
        "diff --git a/bin.dat b/bin.dat",
        "index 8a10ed8..aa6d014 100644",
        "Binary files a/bin.dat and b/bin.dat differ"
    )

    let diffs = DiffParser.parse(output)

    #expect(diffs.count == 1)
    let diff = diffs[0]
    #expect(diff.oldPath == "bin.dat")
    #expect(diff.newPath == "bin.dat")
    #expect(diff.isBinary == true)
    #expect(diff.hunks.isEmpty)
}

@Test func noNewlineAtEOFMarkerFlagsThePrecedingLineOnly() {
    let output = fixture(
        "diff --git a/nonl.txt b/nonl.txt",
        "index f8be7bb..82454bc 100644",
        "--- a/nonl.txt",
        "+++ b/nonl.txt",
        "@@ -1,2 +1,2 @@",
        " line1",
        "-line2",
        "\\ No newline at end of file",
        "+line2changed",
        "\\ No newline at end of file"
    )

    let diffs = DiffParser.parse(output)

    #expect(diffs.count == 1)
    #expect(diffs[0].hunks[0].lines == [
        DiffLine(kind: .context, text: "line1", oldLine: 1, newLine: 1, noNewlineAtEOF: false),
        DiffLine(kind: .deletion, text: "line2", oldLine: 2, newLine: nil, noNewlineAtEOF: true),
        DiffLine(kind: .addition, text: "line2changed", oldLine: nil, newLine: 2, noNewlineAtEOF: true),
    ])
}

@Test func crlfLineKeepsCarriageReturnInText() {
    // Only body/content lines carry \r for a CRLF file; header/hunk lines
    // (diff --git, index, ---, +++, @@) never do — matches real git output.
    let output = [
        "diff --git a/crlf.txt b/crlf.txt",
        "index b87108a..68ed32c 100644",
        "--- a/crlf.txt",
        "+++ b/crlf.txt",
        "@@ -1,3 +1,3 @@",
        " line1\r",
        "-line2\r",
        "+CHANGED\r",
        " line3\r",
    ].joined(separator: "\n") + "\n"

    let diffs = DiffParser.parse(output)

    #expect(diffs.count == 1)
    #expect(diffs[0].hunks[0].lines == [
        DiffLine(kind: .context, text: "line1\r", oldLine: 1, newLine: 1),
        DiffLine(kind: .deletion, text: "line2\r", oldLine: 2, newLine: nil),
        DiffLine(kind: .addition, text: "CHANGED\r", oldLine: nil, newLine: 2),
        DiffLine(kind: .context, text: "line3\r", oldLine: 3, newLine: 3),
    ])
}

@Test func optionalHunkCountHeaderDefaultsCountToOne() {
    let output = fixture(
        "diff --git a/single.txt b/single.txt",
        "index 0b31459..f679e95 100644",
        "--- a/single.txt",
        "+++ b/single.txt",
        "@@ -1 +1 @@",
        "-onlyline",
        "+changedline"
    )

    let diffs = DiffParser.parse(output)

    #expect(diffs.count == 1)
    let hunk = diffs[0].hunks[0]
    #expect(hunk.oldStart == 1 && hunk.oldCount == 1)
    #expect(hunk.newStart == 1 && hunk.newCount == 1)
    #expect(hunk.header == "@@ -1 +1 @@")
    #expect(hunk.lines == [
        DiffLine(kind: .deletion, text: "onlyline", oldLine: 1, newLine: nil),
        DiffLine(kind: .addition, text: "changedline", oldLine: nil, newLine: 1),
    ])
}
