import Foundation

/// Pure parser for `git diff`/`git show` unified diff output. No `Process`,
/// no I/O — plain functions over `String` so it is unit-testable without
/// invoking git.
///
/// Splits on "\n" via `components(separatedBy:)` rather than
/// `String.split(separator:)` — Swift's `Character`-based splitting treats
/// "\r\n" as a single grapheme cluster and would silently fail to split
/// CRLF content at all, which would break the whole file into one blob.
/// `components(separatedBy:)` operates below grapheme-cluster level and
/// splits on "\n" while leaving any preceding "\r" attached to the line it
/// terminates — exactly the CRLF fidelity `DiffLine.text` needs to preserve.
public enum DiffParser {
    /// Parses `git diff`/`git show` unified output into per-file diffs.
    /// Dispatch by leading token: "diff --git" starts a file; "old mode"/
    /// "new mode"/"index "/"similarity"/"rename "/"copy " are header noise
    /// (consumed, mostly ignored, but "--- a/"/"+++ b/" set the paths);
    /// "Binary files " sets isBinary; "@@ " starts a hunk (parse the
    /// ranges); " "/"+"/"-" are hunk body lines; "\ No newline at end of
    /// file" flags the PRECEDING emitted line. Unknown lines outside a hunk
    /// are skipped (forward-compat). Empty input -> [].
    public static func parse(_ output: String) -> [FileDiff] {
        guard !output.isEmpty else { return [] }

        var files: [FileDiff] = []

        var oldPath: String?
        var newPath: String?
        var isBinary = false
        var hunks: [Hunk] = []
        var hasOpenFile = false

        var hunkHeader: String?
        var oldStart = 0, newStart = 0
        var oldCount = 0, newCount = 0
        var oldLine = 0, newLine = 0
        var hunkLines: [DiffLine] = []

        func finalizeHunk() {
            guard let header = hunkHeader else { return }
            hunks.append(Hunk(
                oldStart: oldStart,
                oldCount: oldCount,
                newStart: newStart,
                newCount: newCount,
                header: header,
                lines: hunkLines
            ))
            hunkHeader = nil
            hunkLines = []
        }

        func finalizeFile() {
            finalizeHunk()
            if hasOpenFile, let old = oldPath, let new = newPath {
                files.append(FileDiff(oldPath: old, newPath: new, isBinary: isBinary, hunks: hunks))
            }
            oldPath = nil
            newPath = nil
            isBinary = false
            hunks = []
            hasOpenFile = false
        }

        for rawLine in output.components(separatedBy: "\n") {
            if rawLine.hasPrefix("diff --git ") {
                finalizeFile()
                hasOpenFile = true
                if let paths = parseDiffGitLine(rawLine) {
                    oldPath = paths.old
                    newPath = paths.new
                }
                continue
            }

            guard hasOpenFile else { continue }

            // File-header lines ("--- a/…", "+++ b/…", "Binary files …")
            // only ever appear before a file's first hunk. Restrict these
            // checks to that pre-hunk region: once a hunk is open, a body
            // line whose content starts with "-- " (a deleted SQL/Lua/Haskell
            // comment reads as raw "--- …") or "++ " would otherwise be
            // misparsed as a header — silently dropped, corrupting the path
            // and every following line number in the hunk. `hunks.isEmpty`
            // covers between-hunk gaps too; git never re-emits a header line
            // after the first `@@`.
            if hunkHeader == nil, hunks.isEmpty {
                if rawLine.hasPrefix("--- ") {
                    oldPath = parsePathLine(rawLine, prefixLength: 4)
                    continue
                }
                if rawLine.hasPrefix("+++ ") {
                    newPath = parsePathLine(rawLine, prefixLength: 4)
                    continue
                }
                if rawLine.hasPrefix("Binary files "), rawLine.hasSuffix(" differ") {
                    isBinary = true
                    continue
                }
            }
            if rawLine.hasPrefix("@@ ") {
                finalizeHunk()
                if let ranges = parseHunkHeader(rawLine) {
                    hunkHeader = rawLine
                    oldStart = ranges.oldStart
                    oldCount = ranges.oldCount
                    newStart = ranges.newStart
                    newCount = ranges.newCount
                    oldLine = ranges.oldStart
                    newLine = ranges.newStart
                    hunkLines = []
                }
                continue
            }

            guard hunkHeader != nil else {
                // Header noise ("old mode"/"new mode"/"index "/"similarity"/
                // "rename "/"copy ") or any other unrecognized line outside a
                // hunk — skipped for forward compatibility.
                continue
            }

            if rawLine.hasPrefix("\\ No newline at end of file") {
                if let last = hunkLines.popLast() {
                    hunkLines.append(DiffLine(
                        kind: last.kind,
                        text: last.text,
                        oldLine: last.oldLine,
                        newLine: last.newLine,
                        noNewlineAtEOF: true
                    ))
                }
                continue
            }

            guard let marker = rawLine.first else { continue }
            let text = String(rawLine.dropFirst())
            switch marker {
            case " ":
                hunkLines.append(DiffLine(kind: .context, text: text, oldLine: oldLine, newLine: newLine))
                oldLine += 1
                newLine += 1
            case "+":
                hunkLines.append(DiffLine(kind: .addition, text: text, oldLine: nil, newLine: newLine))
                newLine += 1
            case "-":
                hunkLines.append(DiffLine(kind: .deletion, text: text, oldLine: oldLine, newLine: nil))
                oldLine += 1
            default:
                // Unrecognized hunk-body marker — skipped for forward compatibility.
                continue
            }
        }

        finalizeFile()
        return files
    }

    // MARK: - Line parsing helpers

    /// Extracts `(old, new)` from a `diff --git a/<old> b/<new>` line. This
    /// is the sole path source for pure renames/copies (no content change)
    /// and binary files, where "--- "/"+++ " are absent. Splits on the
    /// first " b/" — ambiguous if a path itself contains that literal
    /// substring, an accepted limitation of this fallback.
    private static func parseDiffGitLine(_ line: String) -> (old: String, new: String)? {
        let prefix = "diff --git "
        guard line.hasPrefix(prefix) else { return nil }
        let rest = line.dropFirst(prefix.count)
        guard let separatorRange = rest.range(of: " b/") else { return nil }
        let oldPart = rest[rest.startIndex..<separatorRange.lowerBound]
        let newPart = rest[separatorRange.upperBound...]
        guard oldPart.hasPrefix("a/") else { return nil }
        return (String(oldPart.dropFirst(2)), String(newPart))
    }

    /// Strips a 4-char prefix ("--- "/"+++ ") and then the "a/"/"b/" marker,
    /// except for the verbatim "/dev/null" (no prefix to strip).
    private static func parsePathLine(_ line: String, prefixLength: Int) -> String {
        let rest = String(line.dropFirst(prefixLength))
        if rest == "/dev/null" { return rest }
        if rest.hasPrefix("a/") || rest.hasPrefix("b/") {
            return String(rest.dropFirst(2))
        }
        return rest
    }

    /// Parses `@@ -oldStart[,oldCount] +newStart[,newCount] @@[ trailing]`.
    /// Trailing context text after the closing "@@" (git's nearest-preceding
    /// section-heading heuristic) is ignored here — the raw line is kept
    /// verbatim as `Hunk.header` by the caller.
    private static func parseHunkHeader(
        _ line: String
    ) -> (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int)? {
        guard line.hasPrefix("@@ ") else { return nil }
        let rest = line.dropFirst(3)
        let parts = rest.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        guard let old = parseRange(parts[0], expectedSign: "-") else { return nil }
        guard let new = parseRange(parts[1], expectedSign: "+") else { return nil }
        return (old.start, old.count, new.start, new.count)
    }

    /// Parses one side of a hunk header range: `-start[,count]` or
    /// `+start[,count]`. A missing count means count 1 (`@@ -1 +1 @@`).
    private static func parseRange(_ token: Substring, expectedSign: Character) -> (start: Int, count: Int)? {
        guard token.first == expectedSign else { return nil }
        let body = token.dropFirst()
        if let commaIndex = body.firstIndex(of: ",") {
            guard let start = Int(body[body.startIndex..<commaIndex]) else { return nil }
            guard let count = Int(body[body.index(after: commaIndex)...]) else { return nil }
            return (start, count)
        }
        guard let start = Int(body) else { return nil }
        return (start, 1)
    }
}
