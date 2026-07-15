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

    /// True when this is `GitClient.restoreUndoSnapshot`'s "repository has
    /// moved on since the snapshot" guard — the repo's HEAD changed (an
    /// external commit, another sync) since the snapshot was taken, so the
    /// recorded `UndoRecord` is now known-stale and safe to discard, unlike
    /// a dirty-clobber refusal from `git reset --keep` itself, which the
    /// caller should leave intact so the user can retry after cleaning up.
    public var isMovedOnSinceSnapshot: Bool {
        stderr.contains("moved on")
    }

    public init(command: String, exitCode: Int32, stderr: String) {
        self.command = command
        self.exitCode = exitCode
        self.stderr = stderr
    }
}
