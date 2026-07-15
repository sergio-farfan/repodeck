import Foundation

/// Builds byte-exact, `git apply`-ready unified-diff patches for ONE hunk of
/// one file — the primitive hunk-level staging/unstaging is built on. Feeds
/// `GitClient.applyPatch`, which pipes the returned string to
/// `git apply --cached [--reverse] --whitespace=nowarn -` on stdin.
///
/// A single wrong byte (a missing `\r`, a miscounted `@@` header, a
/// misplaced "\ No newline at end of file") makes `git apply` reject the
/// whole patch — there is no partial-credit here, hence the emphasis on
/// recomputing (never trusting) counts and preserving `DiffLine.text`
/// verbatim.
public enum PatchBuilder {
    /// Builds a minimal, applyable unified-diff patch for ONE hunk of one
    /// file, suitable for `git apply --cached [--reverse]`. Emits:
    ///   "diff --git a/<old> b/<new>"        (helps git identify the file)
    ///   "--- a/<old>"  (or "--- /dev/null" for an added file)
    ///   "+++ b/<new>"  (or "+++ /dev/null" for a deleted file)
    ///   the recomputed "@@ -oldStart,oldCount +newStart,newCount @@" header
    ///   each hunk line with its +/-/space marker and original text (CRLF preserved)
    ///   "\ No newline at end of file" after any line flagged noNewlineAtEOF
    /// Joined with "\n", with a trailing "\n". Counts are RECOMPUTED from the
    /// line list (context+deletions => old count; context+additions => new
    /// count), never trusted from the parsed Hunk. `reverse` swaps +/- and
    /// the old/new starts+counts (used for UNSTAGING a hunk from the index).
    public static func patch(for hunk: Hunk, in file: FileDiff, reverse: Bool) -> String {
        // Counts from the ORIGINAL (non-reversed) line kinds — the parsed
        // Hunk's own oldCount/newCount are never trusted, since a caller
        // could hand us a hunk whose header no longer matches its lines
        // (or, under `reverse`, we need both the "as-is" and swapped view).
        var oldCount = 0
        var newCount = 0
        for line in hunk.lines {
            switch line.kind {
            case .context:
                oldCount += 1
                newCount += 1
            case .deletion:
                oldCount += 1
            case .addition:
                newCount += 1
            }
        }

        // `reverse` swaps old<->new wholesale: the patch now describes
        // undoing the change, so what was the "new" side becomes the "old"
        // side and vice versa, for both the start line and the count.
        let oldStart = reverse ? hunk.newStart : hunk.oldStart
        let newStart = reverse ? hunk.oldStart : hunk.newStart
        let finalOldCount = reverse ? newCount : oldCount
        let finalNewCount = reverse ? oldCount : newCount

        var output: [String] = [
            "diff --git \(headerPath(file.oldPath, prefix: "a/")) \(headerPath(file.newPath, prefix: "b/"))",
            "--- \(headerPath(file.oldPath, prefix: "a/"))",
            "+++ \(headerPath(file.newPath, prefix: "b/"))",
            "@@ -\(oldStart),\(finalOldCount) +\(newStart),\(finalNewCount) @@",
        ]

        for line in hunk.lines {
            output.append(marker(for: line.kind, reverse: reverse) + line.text)
            if line.noNewlineAtEOF {
                // git places this immediately after the +/-/space line it
                // applies to; under `reverse` the marker on that line has
                // already flipped above, but the note follows the same
                // textual line either way.
                output.append("\\ No newline at end of file")
            }
        }

        return output.joined(separator: "\n") + "\n"
    }

    /// The +/-/space marker for one line, flipped under `reverse` (additions
    /// become deletions and vice versa; context is unaffected).
    private static func marker(for kind: DiffLine.Kind, reverse: Bool) -> String {
        switch kind {
        case .context:
            return " "
        case .addition:
            return reverse ? "-" : "+"
        case .deletion:
            return reverse ? "+" : "-"
        }
    }

    /// Re-adds the `a/`/`b/` prefix `DiffParser` stripped, except
    /// `/dev/null` (an added file's old side, or a deleted file's new side)
    /// is kept verbatim — it never gets a prefix, matching what `git diff`
    /// itself emits.
    private static func headerPath(_ path: String, prefix: String) -> String {
        path == "/dev/null" ? path : prefix + path
    }
}
