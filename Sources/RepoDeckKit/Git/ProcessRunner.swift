import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Scheduling lane for a subprocess: interactive work (user-initiated
/// actions, status refreshes) always beats background work (auto-fetch,
/// integrations polling) for limiter slots.
public enum SubprocessPriority: Sendable {
    case interactive
    case background
}

/// Result of a completed subprocess invocation.
///
/// Only this type crosses isolation boundaries; the underlying `Process`/`Pipe`
/// objects never leave `ProcessRunner.run`.
public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: String
    public let outputTruncated: Bool
    /// True when the timeout watchdog (see `ProcessRunner.run(timeout:)`) had
    /// to intervene because the child outlived its deadline. When true, the
    /// exit code reflects the SIGTERM/SIGKILL signal exit, not a real
    /// command failure.
    public let timedOut: Bool

    public init(
        exitCode: Int32,
        stdout: Data,
        stderr: String,
        outputTruncated: Bool,
        timedOut: Bool = false
    ) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.outputTruncated = outputTruncated
        self.timedOut = timedOut
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
        maxOutputBytes: Int? = nil,
        priority: SubprocessPriority = .interactive,
        timeout: Duration? = nil
    ) async throws -> ProcessResult {
        // (Req 3, 10) Acquire a global slot; release on every exit path. The
        // releaser must pass the same priority the acquirer used.
        await limiter.acquire(priority)
        defer { Task { await limiter.release(priority) } }

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
        // Watchdog bookkeeping: a plain one-shot flag (not a continuation —
        // nothing awaits it) telling the watchdog task whether the child has
        // already exited on its own, so it never signals a pid that might
        // since have been reused by the OS.
        let watchdogState = WatchdogState()
        process.terminationHandler = { _ in
            Task {
                await watchdogState.markTerminated()
                await termination.signal()
            }
        }

        // Launching may fail (e.g. nonexistent executable); let it throw.
        try process.run()

        // pid is Sendable, unlike Process — capture it for cancellation.
        let pid = process.processIdentifier

        // Timeout watchdog: SIGTERM, then SIGKILL five seconds later if the
        // child still hasn't exited. A no-op when `timeout` is nil.
        let watchdogTask: Task<Void, Never>? = timeout.map { deadline in
            Task {
                try? await Task.sleep(for: deadline)
                guard !(await watchdogState.hasTerminated) else { return }
                await watchdogState.markTimedOut()
                kill(pid, SIGTERM)
                try? await Task.sleep(for: .seconds(5))
                guard !(await watchdogState.hasTerminated) else { return }
                kill(pid, SIGKILL)
            }
        }

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
            // Termination is signalled; stop the watchdog (harmless if it
            // already fired or if there is no watchdog at all).
            watchdogTask?.cancel()

            return ProcessResult(
                exitCode: process.terminationStatus,
                stdout: stdoutData,
                stderr: stderrText,
                outputTruncated: truncated,
                timedOut: await watchdogState.timedOut
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

/// Actor-based two-tier FIFO counting semaphore. No locks, no
/// `nonisolated(unsafe)`.
///
/// Interactive work always beats background work: an interactive `acquire`
/// only ever competes for the shared `available` pool, while background work
/// is additionally capped at `backgroundLimit` concurrent slots (of the
/// shared `limit`) so it can never starve interactive callers of the
/// remaining `limit - backgroundLimit` slots. `release` hands a freed slot
/// directly to the oldest interactive waiter if any (queue-jump), else to the
/// oldest background waiter if the background cap allows, else returns it to
/// `available` — a slot handed directly to a waiter keeps `available`
/// consumed the whole time, so there is never an increment-then-decrement
/// race.
actor ConcurrencyLimiter {
    private let limit: Int
    private let backgroundLimit: Int
    private var available: Int
    private var interactiveWaiters: [CheckedContinuation<Void, Never>] = []
    private var backgroundWaiters: [CheckedContinuation<Void, Never>] = []
    private var activeBackground: Int = 0

    init(limit: Int, backgroundLimit: Int = 4) {
        self.limit = limit
        self.backgroundLimit = backgroundLimit
        self.available = limit
    }

    func acquire(_ priority: SubprocessPriority) async {
        switch priority {
        case .interactive:
            if available > 0 {
                available -= 1
                return
            }
            await withCheckedContinuation { continuation in
                interactiveWaiters.append(continuation)
            }

        case .background:
            if available > 0 && activeBackground < backgroundLimit {
                available -= 1
                activeBackground += 1
                return
            }
            await withCheckedContinuation { continuation in
                backgroundWaiters.append(continuation)
            }
        }
    }

    /// The releaser must pass the same priority it acquired with.
    func release(_ priority: SubprocessPriority) {
        if case .background = priority {
            activeBackground -= 1
        }

        if !interactiveWaiters.isEmpty {
            // Queue-jump: interactive waiters always resume before
            // background waiters, regardless of parking order.
            let next = interactiveWaiters.removeFirst()
            next.resume()
        } else if !backgroundWaiters.isEmpty && activeBackground < backgroundLimit {
            activeBackground += 1
            let next = backgroundWaiters.removeFirst()
            next.resume()
        } else {
            available = min(available + 1, limit)
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

// MARK: - Timeout watchdog bookkeeping

/// Plain one-shot flags shared between `ProcessRunner.run` and its timeout
/// watchdog task. Unlike `TerminationSignal`, nothing ever awaits these —
/// they're polled once the watchdog wakes from its sleep — so a pair of
/// booleans is enough.
private actor WatchdogState {
    private(set) var hasTerminated = false
    private(set) var timedOut = false

    /// Set from `Process.terminationHandler`, before signalling
    /// `TerminationSignal`, so a watchdog waking up after normal exit never
    /// sends a signal to a pid the OS may since have reused.
    func markTerminated() { hasTerminated = true }

    /// Set by the watchdog when it decides to intervene.
    func markTimedOut() { timedOut = true }
}
