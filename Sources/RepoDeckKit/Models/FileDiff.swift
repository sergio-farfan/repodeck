import Foundation

/// One line of a unified diff.
public struct DiffLine: Hashable, Sendable {
    public enum Kind: Sendable { case context, addition, deletion }
    public let kind: Kind
    /// Line text WITHOUT the leading +/-/space marker, but WITH any trailing
    /// \r preserved (CRLF fidelity matters for later hunk staging).
    public let text: String
    /// 1-based line number in the OLD file (nil for additions).
    public let oldLine: Int?
    /// 1-based line number in the NEW file (nil for deletions).
    public let newLine: Int?
    /// True when a "\ No newline at end of file" marker followed this line.
    public let noNewlineAtEOF: Bool

    public init(kind: Kind, text: String, oldLine: Int?, newLine: Int?, noNewlineAtEOF: Bool = false) {
        self.kind = kind
        self.text = text
        self.oldLine = oldLine
        self.newLine = newLine
        self.noNewlineAtEOF = noNewlineAtEOF
    }
}

/// One @@ hunk.
public struct Hunk: Identifiable, Hashable, Sendable {
    public let oldStart: Int
    public let oldCount: Int
    public let newStart: Int
    public let newCount: Int
    /// The raw @@ header line as git emitted it (kept verbatim for display
    /// and as a cross-check; hunk staging recomputes counts, never trusts them).
    public let header: String
    public let lines: [DiffLine]
    public var id: String { header + "\(oldStart)-\(newStart)" }

    public init(oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, header: String, lines: [DiffLine]) {
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.header = header
        self.lines = lines
    }
}

/// One file's diff.
public struct FileDiff: Identifiable, Hashable, Sendable {
    public let oldPath: String            // "a/…" path minus prefix; "/dev/null" for new files
    public let newPath: String            // "b/…" path minus prefix; "/dev/null" for deletions
    public let isBinary: Bool             // "Binary files … differ" — hunks empty
    public let hunks: [Hunk]
    public let oldMode: String?
    public let newMode: String?
    /// Lossy text is useful for a preview, but must never become an index patch.
    public let isLosslessUTF8: Bool

    public var hunkActionUnavailableReason: String? {
        if !isLosslessUTF8 {
            return "This diff contains text outside UTF-8. Use the whole-file action to preserve its original bytes."
        }
        if isBinary { return "Binary files require a whole-file action." }
        if (oldPath != "/dev/null" && oldMode == nil) || (newPath != "/dev/null" && newMode == nil) {
            return "This diff is missing file mode information. Refresh it or use the whole-file action."
        }
        if [oldMode, newMode].compactMap({ $0 }).contains(where: { $0 != "100644" && $0 != "100755" }) {
            return "Symlinks and submodules require a whole-file action."
        }
        if let oldMode, let newMode, oldMode != newMode {
            return "File mode changes require a whole-file action."
        }
        if oldPath != newPath, oldPath != "/dev/null", newPath != "/dev/null" {
            return "Renames and copies require a whole-file action."
        }
        return nil
    }

    public var canApplyHunks: Bool { hunkActionUnavailableReason == nil }
    /// Display path: newPath unless it's /dev/null (deletion), then oldPath.
    public var displayPath: String { newPath == "/dev/null" ? oldPath : newPath }
    public var id: String { oldPath + "→" + newPath }

    public init(
        oldPath: String, newPath: String, isBinary: Bool, hunks: [Hunk],
        oldMode: String? = nil, newMode: String? = nil, isLosslessUTF8: Bool = true
    ) {
        self.oldPath = oldPath
        self.newPath = newPath
        self.isBinary = isBinary
        self.hunks = hunks
        self.oldMode = oldMode
        self.newMode = newMode
        self.isLosslessUTF8 = isLosslessUTF8
    }
}
