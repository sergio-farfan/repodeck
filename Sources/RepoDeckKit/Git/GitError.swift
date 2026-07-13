import Foundation

public struct GitError: Error, LocalizedError, Sendable {
    public let command: String           // e.g. "git -C /path status --porcelain=v2"
    public let exitCode: Int32
    public let stderr: String

    public var errorDescription: String? {
        stderr.isEmpty ? "git exited with \(exitCode)" : stderr
    }

    /// True when this error is a push rejected as non-fast-forward — the
    /// remote has commits the local branch doesn't. Matching stderr text is
    /// locale-stable because `ProcessRunner` forces `LC_ALL=C` on every
    /// child process. "stale info" (a `--force-with-lease` artifact) is
    /// deliberately excluded — RepoDeck never force-pushes.
    public var isNonFastForwardPushRejection: Bool {
        stderr.contains("[rejected]")
            && (stderr.contains("non-fast-forward") || stderr.contains("fetch first"))
    }

    public init(command: String, exitCode: Int32, stderr: String) {
        self.command = command
        self.exitCode = exitCode
        self.stderr = stderr
    }
}
