import Foundation
import Testing
@testable import RepoDeckKit

/// Pure, string-level tests for `PatchBuilder`. Fixture `Hunk`/`FileDiff`
/// values are built directly (no git subprocess) — the end-to-end proof
/// that a built patch is actually accepted by `git apply --cached` lives in
/// `GitClientIntegrationTests`.
@Suite struct PatchBuilderTests {
    private func file(oldPath: String = "f.txt", newPath: String = "f.txt") -> FileDiff {
        FileDiff(oldPath: oldPath, newPath: newPath, isBinary: false, hunks: [])
    }

    @Test func recomputesHeaderCountsForAMixedHunkRatherThanTrustingTheParsedHunk() {
        let hunk = Hunk(
            // Deliberately wrong oldCount/newCount on the fixture Hunk — the
            // patch must recompute from the line list, never trust these.
            oldStart: 5, oldCount: 999, newStart: 5, newCount: 999,
            header: "@@ -5,999 +5,999 @@",
            lines: [
                DiffLine(kind: .context, text: "ctx1", oldLine: 5, newLine: 5),
                DiffLine(kind: .deletion, text: "old", oldLine: 6, newLine: nil),
                DiffLine(kind: .addition, text: "new1", oldLine: nil, newLine: 6),
                DiffLine(kind: .addition, text: "new2", oldLine: nil, newLine: 7),
                DiffLine(kind: .context, text: "ctx2", oldLine: 7, newLine: 8),
            ]
        )

        let patch = PatchBuilder.patch(for: hunk, in: file(), reverse: false)
        let lines = patch.components(separatedBy: "\n")

        #expect(lines[0] == "diff --git a/f.txt b/f.txt")
        #expect(lines[1] == "--- a/f.txt")
        #expect(lines[2] == "+++ b/f.txt")
        // oldCount = context(2) + deletion(1) = 3; newCount = context(2) + addition(2) = 4.
        #expect(lines[3] == "@@ -5,3 +5,4 @@")
        #expect(lines[4] == " ctx1")
        #expect(lines[5] == "-old")
        #expect(lines[6] == "+new1")
        #expect(lines[7] == "+new2")
        #expect(lines[8] == " ctx2")
        #expect(patch.hasSuffix("\n"))
    }

    @Test func reverseSwapsMarkersAndStartsCounts() {
        let hunk = Hunk(
            oldStart: 5, oldCount: 1, newStart: 5, newCount: 2,
            header: "@@ -5 +5,2 @@",
            lines: [
                DiffLine(kind: .context, text: "ctx", oldLine: 5, newLine: 5),
                DiffLine(kind: .addition, text: "new", oldLine: nil, newLine: 6),
            ]
        )

        let patch = PatchBuilder.patch(for: hunk, in: file(), reverse: true)
        let lines = patch.components(separatedBy: "\n")

        // Non-reverse counts: oldCount=1 (context only), newCount=2
        // (context+addition). Reversed, old/new start+count swap, and the
        // addition becomes a deletion.
        #expect(lines[3] == "@@ -5,2 +5,1 @@")
        #expect(lines[4] == " ctx")
        #expect(lines[5] == "-new")
    }

    @Test func noNewlineAtEOFFollowsItsOwnLineAndFlipsMarkerUnderReverse() {
        let hunk = Hunk(
            oldStart: 1, oldCount: 1, newStart: 1, newCount: 1,
            header: "@@ -1 +1 @@",
            lines: [
                DiffLine(kind: .deletion, text: "old", oldLine: 1, newLine: nil, noNewlineAtEOF: true),
                DiffLine(kind: .addition, text: "new", oldLine: nil, newLine: 1, noNewlineAtEOF: true),
            ]
        )

        let forward = PatchBuilder.patch(for: hunk, in: file(), reverse: false)
        #expect(forward.contains("-old\n\\ No newline at end of file\n+new\n\\ No newline at end of file\n"))

        let reverse = PatchBuilder.patch(for: hunk, in: file(), reverse: true)
        // Markers flip, but the "\ No newline" note still immediately
        // follows the same textual line.
        #expect(reverse.contains("+old\n\\ No newline at end of file\n-new\n\\ No newline at end of file\n"))
    }

    @Test func crlfTextRoundTripsIntoThePatchWithCarriageReturnPreserved() {
        let hunk = Hunk(
            oldStart: 1, oldCount: 1, newStart: 1, newCount: 1,
            header: "@@ -1 +1 @@",
            lines: [
                DiffLine(kind: .deletion, text: "old\r", oldLine: 1, newLine: nil),
                DiffLine(kind: .addition, text: "new\r", oldLine: nil, newLine: 1),
            ]
        )

        let patch = PatchBuilder.patch(for: hunk, in: file(), reverse: false)

        // The \r must land right before the joining \n — not stripped, not
        // duplicated.
        #expect(patch.contains("-old\r\n"))
        #expect(patch.contains("+new\r\n"))
        #expect(!patch.contains("-old\r\r"))
    }

    @Test func addedFileHeaderUsesTheRealFilenameOnBothDiffGitSidesAndEmitsNewFileMode() {
        let hunk = Hunk(
            oldStart: 0, oldCount: 0, newStart: 1, newCount: 1,
            header: "@@ -0,0 +1 @@",
            lines: [DiffLine(kind: .addition, text: "new", oldLine: nil, newLine: 1)]
        )
        let diffFile = file(oldPath: "/dev/null", newPath: "new.txt")

        let patch = PatchBuilder.patch(for: hunk, in: diffFile, reverse: false)
        let lines = patch.components(separatedBy: "\n")

        // git never puts /dev/null on the `diff --git` line — both sides
        // name the real file even for an add.
        #expect(lines[0] == "diff --git a/new.txt b/new.txt")
        #expect(lines[1] == "new file mode 100644")
        #expect(lines[2] == "--- /dev/null")
        #expect(lines[3] == "+++ b/new.txt")
    }

    @Test func deletedFileHeaderUsesTheRealFilenameOnBothDiffGitSidesAndEmitsDeletedFileMode() {
        let hunk = Hunk(
            oldStart: 1, oldCount: 1, newStart: 0, newCount: 0,
            header: "@@ -1 +0,0 @@",
            lines: [DiffLine(kind: .deletion, text: "old", oldLine: 1, newLine: nil)]
        )
        let diffFile = file(oldPath: "old.txt", newPath: "/dev/null")

        let patch = PatchBuilder.patch(for: hunk, in: diffFile, reverse: false)
        let lines = patch.components(separatedBy: "\n")

        // git never puts /dev/null on the `diff --git` line — both sides
        // name the real file even for a delete.
        #expect(lines[0] == "diff --git a/old.txt b/old.txt")
        #expect(lines[1] == "deleted file mode 100644")
        #expect(lines[2] == "--- a/old.txt")
        #expect(lines[3] == "+++ /dev/null")
    }

    @Test func reverseSwapsStartsWhenOldStartDiffersFromNewStart() {
        // Every existing reverse fixture has oldStart == newStart, so a
        // dropped start-swap would pass silently. Here oldStart(5) !=
        // newStart(9), and forward vs. reverse counts also differ (2 vs 3),
        // so both the start-swap and the count-swap are independently
        // checkable, not just coincidentally equal.
        let hunk = Hunk(
            oldStart: 5, oldCount: 999, newStart: 9, newCount: 999,
            header: "@@ -5,999 +9,999 @@",
            lines: [
                DiffLine(kind: .context, text: "ctx", oldLine: 5, newLine: 9),
                DiffLine(kind: .deletion, text: "old", oldLine: 6, newLine: nil),
                DiffLine(kind: .addition, text: "new1", oldLine: nil, newLine: 10),
                DiffLine(kind: .addition, text: "new2", oldLine: nil, newLine: 11),
            ]
        )

        // Forward: oldCount = context(1)+deletion(1) = 2; newCount = context(1)+addition(2) = 3.
        let forward = PatchBuilder.patch(for: hunk, in: file(), reverse: false)
        #expect(forward.components(separatedBy: "\n")[3] == "@@ -5,2 +9,3 @@")

        // Reverse swaps BOTH starts (5<->9) and counts (2<->3).
        let reverse = PatchBuilder.patch(for: hunk, in: file(), reverse: true)
        #expect(reverse.components(separatedBy: "\n")[3] == "@@ -9,3 +5,2 @@")
    }
}
