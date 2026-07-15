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
    ///   "diff --git a/<real-old> b/<real-new>" (ALWAYS the real filename on
    ///     both sides, even for an add/delete — git never puts /dev/null here)
    ///   "new file mode 100644" (add only) or "deleted file mode 100644" (delete only)
    ///     — "add"/"delete" here is evaluated on the DIRECTION this call
    ///     produces: under `reverse`, an add's FileDiff yields a delete-shaped
    ///     patch (and vice versa), since undoing an add IS a delete
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

        // The `diff --git` line NEVER carries `/dev/null` on either side —
        // git always names the real file with `a/`/`b/` prefixes there, even
        // for an add or a delete (only the `---`/`+++` lines below use
        // `/dev/null`, to mark "this side doesn't exist"). This is about
        // identifying the ONE real file involved, which `reverse` never
        // changes — for a modify, oldPath == newPath so this is a no-op;
        // for an add, both sides become newPath; for a delete, both become
        // oldPath.
        let rawIsAdd = file.oldPath == "/dev/null"
        let rawIsDelete = file.newPath == "/dev/null"
        let realOld = rawIsAdd ? file.newPath : file.oldPath
        let realNew = rawIsDelete ? file.oldPath : file.newPath

        // Unlike `realOld`/`realNew` above, the MODE LINE and the
        // `---`/`+++` headers describe the patch's DIRECTION, which `reverse`
        // does flip: reversing a delete (real -> /dev/null) yields a patch
        // that adds the file back (/dev/null -> real), and reversing an add
        // yields one that deletes it. Swapping old/new here — mirroring the
        // oldStart/newStart swap above — before re-deriving isAdd/isDelete
        // is what keeps the mode line and the /dev/null side consistent
        // with the swapped +/- markers below; getting this wrong produces a
        // patch `git apply` rejects (e.g. "deleted file ... still has
        // contents" when the mode line says "deleted" but the body adds a
        // line).
        let effectiveOldPath = reverse ? file.newPath : file.oldPath
        let effectiveNewPath = reverse ? file.oldPath : file.newPath
        let isAdd = effectiveOldPath == "/dev/null"
        let isDelete = effectiveNewPath == "/dev/null"

        var output: [String] = [
            "diff --git a/\(realOld) b/\(realNew)",
        ]
        // Git needs an explicit mode line for `git apply --cached` to know
        // whether this hunk adds or removes a file rather than modifying
        // one. 100644 is the common-case text-file mode; since 8a's
        // FileDiff carries no mode info, a new EXECUTABLE file staged this
        // way would land as 100644 — an accepted v1 limitation, not
        // something to infer here. The same 100644 assumption also makes
        // UNSTAGING a staged delete of a 100755 file inexact: it leaves a
        // residual staged mode change (100755 -> 100644) the user didn't
        // ask for, recoverable via the whole-file unstage control. Carrying
        // real modes through FileDiff (DiffParser sees the mode header lines)
        // is the eventual fix.
        if isAdd {
            output.append("new file mode 100644")
        } else if isDelete {
            output.append("deleted file mode 100644")
        }
        output.append("--- \(headerPath(effectiveOldPath, prefix: "a/"))")
        output.append("+++ \(headerPath(effectiveNewPath, prefix: "b/"))")
        output.append("@@ -\(oldStart),\(finalOldCount) +\(newStart),\(finalNewCount) @@")

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
