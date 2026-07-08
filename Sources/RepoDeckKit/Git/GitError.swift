import Foundation

public struct GitError: Error, LocalizedError, Sendable {
    public let command: String           // e.g. "git -C /path status --porcelain=v2"
    public let exitCode: Int32
    public let stderr: String

    public var errorDescription: String? {
        stderr.isEmpty ? "git exited with \(exitCode)" : stderr
    }

    public init(command: String, exitCode: Int32, stderr: String) {
        self.command = command
        self.exitCode = exitCode
        self.stderr = stderr
    }
}
