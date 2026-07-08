import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Result of a completed subprocess invocation.
///
/// Only this type crosses isolation boundaries; the underlying `Process`/`Pipe`
/// objects never leave `ProcessRunner.run`.
public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: String
    public let outputTruncated: Bool

    public init(exitCode: Int32, stdout: Data, stderr: String, outputTruncated: Bool) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.outputTruncated = outputTruncated
    }
}

/// The single subprocess primitive the whole app funnels through: async,
/// deadlock-free, cancellable, output-capped, and globally concurrency-bounded.
public enum ProcessRunner {
    /// Process-wide cap on concurrent `run` executions.
    static let concurrencyLimit = 6

    /// Shared FIFO counting semaphore bounding git subprocesses across all
    /// repos and bulk operations.
    static let limiter = ConcurrencyLimiter(limit: concurrencyLimit)

    public static func run(
        _ executable: String = GitDefaults.gitPath,
        arguments: [String],
        workingDirectory: URL? = nil,
        environment: [String: String] = [:],
        maxOutputBytes: Int? = nil
    ) async throws -> ProcessResult {
        // (Req 3, 10) Acquire a global slot; release on every exit path.
        await limiter.acquire()
        defer { Task { await limiter.release() } }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }

        // (Req 4) Inherit env, force non-interactive + stable locale, caller wins.
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["LC_ALL"] = "C"
        for (key, value) in environment { env[key] = value }
        process.environment = env

        // (Req 5) Never block on stdin.
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // (Req 6) Bridge termination through a continuation instead of spinning
        // or calling waitUntilExit on a thread. Set before launch so a fast
        // child's exit is never missed.
        let termination = TerminationSignal()
        process.terminationHandler = { _ in
            Task { await termination.signal() }
        }

        // Launching may fail (e.g. nonexistent executable); let it throw.
        try process.run()

        // pid is Sendable, unlike Process — capture it for cancellation.
        let pid = process.processIdentifier

        // (Req 1, 8) Bridge each pipe to a Sendable AsyncStream. The handlers
        // capture only the Sendable continuation; the non-Sendable Process/Pipe
        // stay inside this function body.
        let stdoutStream = makeByteStream(stdoutPipe.fileHandleForReading)
        let stderrStream = makeByteStream(stderrPipe.fileHandleForReading)

        // (Req 7) Terminate the child if the surrounding task is cancelled;
        // the drain loops then end naturally at EOF.
        return await withTaskCancellationHandler {
            // (Req 1) Drain stderr concurrently while draining stdout, both
            // BEFORE waiting for termination — a full pipe would otherwise
            // deadlock the child on large output.
            async let stderrData = drainAll(stderrStream)

            var stdoutData = Data()
            var truncated = false
            for await chunk in stdoutStream {
                stdoutData.append(chunk)
                // (Req 2) Enforce the output cap mid-stream.
                if let cap = maxOutputBytes, stdoutData.count >= cap {
                    truncated = true
                    process.terminate()
                    break
                }
            }

            // (Req 9) stderr decoded lossy UTF-8; stdout stays raw Data.
            let stderrText = String(decoding: await stderrData, as: UTF8.self)

            // Now that both streams are drained, block on actual exit.
            await termination.wait()

            return ProcessResult(
                exitCode: process.terminationStatus,
                stdout: stdoutData,
                stderr: stderrText,
                outputTruncated: truncated
            )
        } onCancel: {
            // Only the Sendable pid crosses into this @Sendable closure.
            kill(pid, SIGTERM)
        }
    }
}

// MARK: - Pipe draining

/// Bridges a readable `FileHandle` to a `Sendable` `AsyncStream<Data>`.
///
/// The `@Sendable` readability handler captures only the stream continuation and
/// operates on the `FileHandle` passed to it, so no non-Sendable state escapes.
private func makeByteStream(_ handle: FileHandle) -> AsyncStream<Data> {
    AsyncStream(Data.self, bufferingPolicy: .unbounded) { continuation in
        handle.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            if data.isEmpty {
                fileHandle.readabilityHandler = nil
                continuation.finish()
            } else {
                continuation.yield(data)
            }
        }
    }
}

/// Accumulates every chunk of a stream to EOF.
private func drainAll(_ stream: AsyncStream<Data>) async -> Data {
    var data = Data()
    for await chunk in stream { data.append(chunk) }
    return data
}

// MARK: - Concurrency limiter

/// Actor-based FIFO counting semaphore. No locks, no `nonisolated(unsafe)`.
actor ConcurrencyLimiter {
    private let limit: Int
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = limit
        self.available = limit
    }

    func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            available = min(available + 1, limit)
        } else {
            // FIFO: hand the freed slot directly to the oldest waiter, so
            // `available` stays consumed.
            let next = waiters.removeFirst()
            next.resume()
        }
    }
}

// MARK: - Termination bridge

/// One-shot async signal fulfilled by `Process.terminationHandler`.
private actor TerminationSignal {
    private var terminated = false
    private var continuation: CheckedContinuation<Void, Never>?

    func signal() {
        if let continuation {
            self.continuation = nil
            continuation.resume()
        } else {
            terminated = true
        }
    }

    func wait() async {
        if terminated { return }
        await withCheckedContinuation { continuation in
            if terminated {
                continuation.resume()
            } else {
                self.continuation = continuation
            }
        }
    }
}
