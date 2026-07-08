import Foundation
import Testing
@testable import RepoDeckKit

@Test("1. Clean repo: headers only")
func cleanRepoHeadersOnly() {
    let status = PorcelainParser.parse([
        "# branch.oid abc123",
        "# branch.head main",
        "# branch.upstream origin/main",
        "# branch.ab +0 -0",
    ])
    #expect(status.branch == "main")
    #expect(status.ahead == 0)
    #expect(status.behind == 0)
    #expect(status.changes.isEmpty)
}

@Test("2. Staged-only change")
func stagedOnlyChange() {
    let status = PorcelainParser.parse([
        "1 A. N... 000000 100644 100644 0000000 e69de29 New.swift",
    ])
    #expect(status.changes == [
        FileChange(path: "New.swift", area: .staged, statusLetter: "A"),
    ])
}

@Test("3. Unstaged-only change")
func unstagedOnlyChange() {
    let status = PorcelainParser.parse([
        "1 .M N... 100644 100644 100644 aaa bbb Existing.swift",
    ])
    #expect(status.changes == [
        FileChange(path: "Existing.swift", area: .unstaged, statusLetter: "M"),
    ])
}

@Test("4. MM fan-out produces staged + unstaged")
func mmFanOut() {
    let status = PorcelainParser.parse([
        "1 MM N... 100644 100644 100644 aaa bbb README.md",
    ])
    #expect(status.changes.count == 2)
    #expect(status.changes.contains(FileChange(path: "README.md", area: .staged, statusLetter: "M")))
    #expect(status.changes.contains(FileChange(path: "README.md", area: .unstaged, statusLetter: "M")))
}

@Test("5. Rename consumes the following NUL record as originalPath")
func renameConsumesOriginalPath() {
    let status = PorcelainParser.parse([
        "2 R. N... 100644 100644 100644 aaa bbb R100 new-name.txt",
        "old-name.txt",
        "? notes.txt",
    ])
    #expect(status.changes == [
        FileChange(path: "new-name.txt", originalPath: "old-name.txt", area: .staged, statusLetter: "R"),
        FileChange(path: "notes.txt", area: .untracked, statusLetter: "U"),
    ])
}

@Test("6. Untracked entry")
func untrackedEntry() {
    let status = PorcelainParser.parse([
        "? notes.txt",
    ])
    #expect(status.changes == [
        FileChange(path: "notes.txt", area: .untracked, statusLetter: "U"),
    ])
}

@Test("7. Unmerged entry keeps both XY characters")
func unmergedEntry() {
    let status = PorcelainParser.parse([
        "u UU N... 100644 100644 100644 100644 h1 h2 h3 conflicted.txt",
    ])
    #expect(status.changes == [
        FileChange(path: "conflicted.txt", area: .unmerged, statusLetter: "UU"),
    ])
}

@Test("8. Detached HEAD keeps literal marker")
func detachedHead() {
    let status = PorcelainParser.parse([
        "# branch.head (detached)",
    ])
    #expect(status.branch == "(detached)")
}

@Test("9. No upstream leaves upstream/ahead/behind nil")
func noUpstream() {
    let status = PorcelainParser.parse([
        "# branch.oid abc123",
        "# branch.head main",
    ])
    #expect(status.upstream == nil)
    #expect(status.ahead == nil)
    #expect(status.behind == nil)
}

@Test("10. Unborn branch keeps literal oid marker")
func unbornBranch() {
    let status = PorcelainParser.parse([
        "# branch.oid (initial)",
    ])
    #expect(status.oid == "(initial)")
}

@Test("11. Path with embedded spaces preserved exactly")
func pathWithSpacesPreserved() {
    let status = PorcelainParser.parse([
        "1 .M N... 100644 100644 100644 aaa bbb my file with spaces.txt",
    ])
    #expect(status.changes == [
        FileChange(path: "my file with spaces.txt", area: .unstaged, statusLetter: "M"),
    ])
}

@Test("12. Truncated output drops the partial final record")
func truncatedOutputDropsPartialRecord() {
    let status = PorcelainParser.parse(
        [
            "# branch.oid abc123",
            "# branch.head main",
            "1 A. N... 000000 100644 100644 0000000 e69de29 New.swift",
            "garbage partial rec",
        ],
        truncated: true
    )
    #expect(status.didHitLimit)
    #expect(status.branch == "main")
    #expect(status.oid == "abc123")
    #expect(status.changes == [
        FileChange(path: "New.swift", area: .staged, statusLetter: "A"),
    ])
}

@Test("13. branch.ab parses ahead/behind")
func branchAbParsesAheadBehind() {
    let status = PorcelainParser.parse([
        "# branch.ab +2 -1",
    ])
    #expect(status.ahead == 2)
    #expect(status.behind == 1)
}
