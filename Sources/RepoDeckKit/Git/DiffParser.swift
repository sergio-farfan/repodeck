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
        parse(output, isLosslessUTF8: true)
    }

    public static func parse(_ output: Data) -> [FileDiff] {
        let lossless = String(data: output, encoding: .utf8)
        return parse(lossless ?? String(decoding: output, as: UTF8.self), isLosslessUTF8: lossless != nil)
    }

    private static func parse(_ output: String, isLosslessUTF8: Bool) -> [FileDiff] {
        guard !output.isEmpty else { return [] }

        var files: [FileDiff] = []

        var oldPath: String?
        var newPath: String?
        var isBinary = false
        var oldMode: String?
        var newMode: String?
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
                files.append(FileDiff(oldPath: old, newPath: new, isBinary: isBinary, hunks: hunks,
                                      oldMode: oldMode, newMode: newMode, isLosslessUTF8: isLosslessUTF8))
            }
            oldPath = nil
            newPath = nil
            isBinary = false
            oldMode = nil
            newMode = nil
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
                if rawLine.hasPrefix("new file mode ") {
                    newMode = String(rawLine.dropFirst(14))
                } else if rawLine.hasPrefix("deleted file mode ") {
                    oldMode = String(rawLine.dropFirst(18))
                } else if rawLine.hasPrefix("old mode ") {
                    oldMode = String(rawLine.dropFirst(9))
                } else if rawLine.hasPrefix("new mode ") {
                    newMode = String(rawLine.dropFirst(9))
                } else if rawLine.hasPrefix("index ") {
                    let fields = rawLine.split(separator: " ")
                    if fields.count == 3 { oldMode = String(fields[2]); newMode = String(fields[2]) }
                } else if rawLine.hasPrefix("rename from ") || rawLine.hasPrefix("copy from ") {
                    oldPath = GitPathCodec.decode(String(rawLine.dropFirst(rawLine.hasPrefix("rename") ? 12 : 10)))
                } else if rawLine.hasPrefix("rename to ") || rawLine.hasPrefix("copy to ") {
                    newPath = GitPathCodec.decode(String(rawLine.dropFirst(rawLine.hasPrefix("rename") ? 10 : 8)))
                }
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
    /// is a fallback when ---/+++ headers are absent. Rename/copy headers
    /// override it; equal paths disambiguate ordinary binary modifications.
    private static func parseDiffGitLine(_ line: String) -> (old: String, new: String)? {
        let prefix = "diff --git "
        guard line.hasPrefix(prefix) else { return nil }
        let rest = String(line.dropFirst(prefix.count))
        var pairs: [(String, String)] = []
        // A separator is a space before the new b/ path, optionally quoted.
        // Decoding each candidate also validates the quoted old side.
        for index in rest.indices where rest[index] == " " {
            let right = String(rest[rest.index(after: index)...])
            guard right.hasPrefix("b/") || right.hasPrefix("\"b/") else { continue }
            guard let old = GitPathCodec.decode(String(rest[..<index])),
                  let new = GitPathCodec.decode(right), old.hasPrefix("a/"), new.hasPrefix("b/") else { continue }
            pairs.append((String(old.dropFirst(2)), String(new.dropFirst(2))))
        }
        return pairs.first(where: { $0.0 == $0.1 }) ?? pairs.first
    }

    /// Strips a 4-char prefix ("--- "/"+++ ") and then the "a/"/"b/" marker,
    /// except for the verbatim "/dev/null" (no prefix to strip).
    private static func parsePathLine(_ line: String, prefixLength: Int) -> String? {
        let raw = String(line.dropFirst(prefixLength))
        // Git appends a tab delimiter to unquoted filenames containing spaces.
        guard let rest = GitPathCodec.decode(raw.hasPrefix("\"") ? raw : String(raw.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)[0])) else { return nil }
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
