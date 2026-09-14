import Foundation
import Synchronization
import Testing
@testable import RepoDeckKit

/// A readiness wait must also observe the command: a failed spawn or an early
/// exit can never produce the marker and must not become a queue-timeout error.
final class ProcessTestCompletion: Sendable {
    enum Outcome: Sendable {
        case completed(exitCode: Int32?, timedOut: Bool)
        case failed(any Error)
    }
    private let state = Mutex<Outcome?>(nil)

    func capture<Value: Sendable>(_ operation: @Sendable () async throws -> Value) async throws -> Value {
        do {
            let value = try await operation()
            let result = value as? ProcessResult
            state.withLock { $0 = .completed(exitCode: result?.exitCode, timedOut: result?.timedOut ?? false) }
            return value
        } catch {
            state.withLock { $0 = .failed(error) }
            throw error
        }
    }

    func checkStillRunning() throws {
        guard let outcome = state.withLock({ $0 }) else { return }
        switch outcome {
        case .failed(let error): throw error
        case .completed(let code, let timedOut):
            throw ProcessReadinessError.exitedBeforeReady(exitCode: code, timedOut: timedOut)
        }
    }
}

enum ProcessReadinessError: Error, Equatable, CustomStringConvertible {
    case exitedBeforeReady(exitCode: Int32?, timedOut: Bool)
    var description: String {
        switch self {
        case .exitedBeforeReady(let code, let timedOut):
            "Command finished before signaling readiness (exit: \(code.map(String.init) ?? "stream completed"), timedOut: \(timedOut))"
        }
    }
}

/// Readiness is reserved for tests whose setup must execute inside the child.
/// Timeout tests use the runner's monotonic execution duration instead.
struct ProcessTestFixture: Sendable {
    let folder: URL
    var ready: URL { folder.appendingPathComponent("ready") }
    var late: URL { folder.appendingPathComponent("late") }
    var release: URL { folder.appendingPathComponent("release") }

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: folder) }

    func waitUntilReady(completion: ProcessTestCompletion) async throws {
        // The full parallel suite shares six process slots. This bounds queue
        // admission separately; it does not relax the execution/cleanup limit.
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while !FileManager.default.fileExists(atPath: ready.path), ContinuousClock.now < deadline {
            try completion.checkStillRunning()
            try await Task.sleep(for: .milliseconds(10))
        }
        if !FileManager.default.fileExists(atPath: ready.path) { try completion.checkStillRunning() }
        try #require(FileManager.default.fileExists(atPath: ready.path), "Child did not signal readiness within the CI queue allowance")
    }

    /// The descendant itself signals readiness, then waits for the test before
    /// starting its delayed side effect. Neither queueing nor late observation
    /// can consume that delay before cancellation is exercised.
    var cancellationArguments: [String] {
        ["-c", "(printf ready > \"$1\"; while [ ! -e \"$3\" ]; do sleep 0.01; done; sleep 1; printf late > \"$2\") & wait", "job", ready.path, late.path, release.path]
    }

    func releaseChild() throws { try Data().write(to: release) }

    static func runMarked(
        script: String,
        timeout: Duration,
        stdin: Data? = nil,
        executable: String = "/bin/sh"
    ) async throws -> ProcessResult {
        let fixture = try Self()
        defer { fixture.remove() }
        let completion = ProcessTestCompletion()
        let task = Task {
            try await completion.capture {
                try await ProcessRunner.run(executable, arguments: ["-c", script, "job", fixture.ready.path],
                    timeout: timeout, stdin: stdin)
            }
        }
        do {
            try await fixture.waitUntilReady(completion: completion)
            return try await task.value
        } catch {
            task.cancel()
            _ = await task.result
            throw error
        }
    }
}

@Suite struct ProcessRunnerTests {
    @Test func gitVersionSucceeds() async throws {
        let result = try await ProcessRunner.run(arguments: ["--version"])
        #expect(result.exitCode == 0)
        #expect(!result.stdout.isEmpty)
        #expect(result.outputTruncated == false)
    }

    @Test func nonexistentExecutableThrows() async {
        await #expect(throws: (any Error).self) {
            _ = try await ProcessRunner.run(
                "/nonexistent/path/to/binary",
                arguments: []
            )
        }
    }

    @Test func exitCodePropagates() async throws {
        let result = try await ProcessRunner.run(
            "/bin/sh",
            arguments: ["-c", "exit 3"]
        )
        #expect(result.exitCode == 3)
    }

    @Test func stderrIsCaptured() async throws {
        let result = try await ProcessRunner.run(
            "/bin/sh",
            arguments: ["-c", "echo err 1>&2; exit 1"]
        )
        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("err"))
    }

    @Test func outputCapTruncates() async throws {
        let result = try await ProcessRunner.run(
            "/bin/sh",
            arguments: ["-c", "yes x | head -c 200000"],
            maxOutputBytes: 50_000
        )
        #expect(result.outputTruncated == true)
        #expect(!result.stdout.isEmpty)
        #expect(result.stdout.count < 200_000)
    }

    @Test func environmentOverrideIsVisible() async throws {
        let result = try await ProcessRunner.run(
            "/bin/sh",
            arguments: ["-c", "echo $LC_ALL"]
        )
        let out = String(decoding: result.stdout, as: UTF8.self)
        #expect(out.trimmingCharacters(in: .whitespacesAndNewlines) == "C")
    }

    @Test func callerEnvironmentWins() async throws {
        let result = try await ProcessRunner.run(
            "/bin/sh",
            arguments: ["-c", "echo $REPODECK_TEST_VAR"],
            environment: ["REPODECK_TEST_VAR": "hello"]
        )
        let out = String(decoding: result.stdout, as: UTF8.self)
        #expect(out.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
    }

    @Test func concurrencyCapSerializesWaves() async throws {
        let start = Date()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    _ = try await ProcessRunner.run(
                        "/bin/sh",
                        arguments: ["-c", "sleep 0.2"]
                    )
                }
            }
            try await group.waitForAll()
        }
        let elapsed = Date().timeIntervalSince(start)
        // 12 sleeps of 0.2s with cap 6 => at least two waves => >= ~0.4s.
        #expect(elapsed >= 0.35)
    }

    // MARK: - Timeout watchdog

    @Test func timeoutKillsHungChildPromptly() async throws {
        let result = try await ProcessRunner.run("/bin/sleep", arguments: ["30"], timeout: .milliseconds(200))
        let elapsed = try #require(result.executionDuration)
        #expect(elapsed >= .milliseconds(200))
        #expect(elapsed < .seconds(2))
        #expect(result.timedOut == true)
        #expect(result.exitCode != 0)
    }

    @Test func timeoutMayPrecedeTheChildReadinessSignal() async throws {
        let fixture = try ProcessTestFixture()
        defer { fixture.remove() }
        let result = try await ProcessRunner.run("/bin/sh", arguments: [
            "-c", "sleep 1; printf ready > \"$1\"; exec /bin/sleep 30", "job", fixture.ready.path
        ], timeout: .milliseconds(200))
        #expect(result.timedOut)
        #expect(result.exitCode != 0)
        let elapsed = try #require(result.executionDuration)
        #expect(elapsed >= .milliseconds(200))
        #expect(elapsed < .seconds(2))
        #expect(!FileManager.default.fileExists(atPath: fixture.ready.path))
    }

    @Test func readinessWaitPropagatesTheActualSpawnError() async throws {
        do {
            _ = try await ProcessTestFixture.runMarked(script: "", timeout: .seconds(10),
                executable: "/nonexistent/repodeck-readiness-fixture")
            Issue.record("Expected the spawn failure")
        } catch let error as POSIXError {
            #expect(error.code == .ENOENT)
        }
    }

    @Test func readinessWaitReportsAnEarlyExitInsteadOfWaitingForAMarker() async {
        await #expect(throws: ProcessReadinessError.exitedBeforeReady(exitCode: 7, timedOut: false)) {
            _ = try await ProcessTestFixture.runMarked(script: "exit 7", timeout: .seconds(10))
        }
    }

    @Test func noFalseTimeoutOnQuickCommand() async throws {
        let result = try await ProcessRunner.run(
            "/bin/sh",
            arguments: ["-c", "exit 0"],
            timeout: .seconds(30)
        )
        #expect(result.timedOut == false)
        #expect(result.exitCode == 0)
    }

    // MARK: - stdin

    @Test func stdinDefaultsToNullDeviceAndDoesNotBlock() async throws {
        // Pins the existing behavior: with no `stdin` argument, a command
        // that reads stdin sees immediate EOF rather than hanging.
        let result = try await ProcessRunner.run(
            "/bin/cat",
            arguments: []
        )
        #expect(result.exitCode == 0)
        #expect(result.stdout.isEmpty)
    }

    @Test func catEchoesSmallStdinExactly() async throws {
        let input = Data("hi\n".utf8)
        let result = try await ProcessRunner.run(
            "/bin/cat",
            arguments: [],
            stdin: input
        )
        #expect(result.exitCode == 0)
        #expect(result.stdout == input)
    }

    @Test func writingStdinToANonReadingChildDoesNotCrashTheProcess() async throws {
        // `/usr/bin/true` exits immediately WITHOUT reading stdin, so our
        // detached write task races a reader that's already gone — the
        // write can hit a closed pipe. Before the fix, the default SIGPIPE
        // disposition terminates this whole test process (exit 141 =
        // 128+SIGPIPE) BEFORE `write(contentsOf:)` can throw, so the
        // existing `try?` never gets a chance to swallow anything. After
        // the fix (F_SETNOSIGPIPE on the write fd), the write instead
        // surfaces a catchable EPIPE that `try?` swallows, and `run`
        // returns normally with the child's real exit code.
        var bytes = [UInt8](repeating: 0, count: 8_000_000)
        for i in 0..<bytes.count { bytes[i] = UInt8(i % 256) }
        let input = Data(bytes)

        let result = try await ProcessRunner.run(
            "/usr/bin/true",
            arguments: [],
            stdin: input
        )
        #expect(result.exitCode == 0)
    }

    @Test func catEchoesMultiMegabyteStdinWithoutDeadlock() async throws {
        // Several MB is large enough to fill the stdin/stdout pipe buffers
        // several times over; a naive "write all of stdin, then start
        // reading stdout" implementation deadlocks here because `cat`
        // blocks writing to a full stdout pipe that nobody is draining yet
        // while we are still blocked writing to its full stdin pipe. This
        // pins that the write happens concurrently with the drain.
        var bytes = [UInt8](repeating: 0, count: 8_000_000)
        for i in 0..<bytes.count { bytes[i] = UInt8(i % 256) }
        let input = Data(bytes)

        let result = try await ProcessRunner.run(
            "/bin/cat",
            arguments: [],
            stdin: input
        )
        #expect(result.exitCode == 0)
        #expect(result.stdout == input)
    }
}

// MARK: - ConcurrencyLimiter (priority tiers)

@Suite struct ConcurrencyLimiterTests {
    /// Actor-guarded ordered log used to assert resumption order deterministically.
    private actor OrderLog {
        private(set) var entries: [String] = []
        func append(_ entry: String) { entries.append(entry) }
    }

    @Test func backgroundIsCappedAtFourWhileInteractiveSlotsRemainReserved() async throws {
        let limiter = ConcurrencyLimiter(limit: 6)

        // Four background acquires succeed immediately.
        for _ in 0..<4 {
            try await limiter.acquire(.background)
        }

        // A fifth background acquire must park (activeBackground == backgroundLimit).
        let fifthBackgroundStarted = OrderLog()
        let fifthBackgroundAcquired = OrderLog()
        let fifthBackgroundTask = Task {
            await fifthBackgroundStarted.append("started")
            try await limiter.acquire(.background)
            await fifthBackgroundAcquired.append("acquired")
        }

        // Give the fifth background task a chance to reach `acquire` and park.
        while await fifthBackgroundStarted.entries.isEmpty {
            await Task.yield()
        }
        // A brief grace period so the parked acquire call has actually
        // registered as a waiter before we assert it hasn't completed.
        try await Task.sleep(for: .milliseconds(50))
        #expect(await fifthBackgroundAcquired.entries.isEmpty)

        // Two of the six slots are still reserved (available == 2): an
        // interactive acquire must succeed immediately, without parking.
        try await limiter.acquire(.interactive)

        // The fifth background acquire is still parked — interactive slots
        // are independent of the background cap.
        #expect(await fifthBackgroundAcquired.entries.isEmpty)

        // Releasing one of the four running background slots must let the
        // parked background acquire through.
        await limiter.release(.background)
        _ = try await fifthBackgroundTask.value
        #expect(await fifthBackgroundAcquired.entries == ["acquired"])
    }

    @Test func interactiveWaiterQueueJumpsAheadOfParkedBackgroundWaiter() async throws {
        let limiter = ConcurrencyLimiter(limit: 6)
        let log = OrderLog()

        // Fill all six slots with a mix of tiers.
        for _ in 0..<4 { try await limiter.acquire(.background) }
        for _ in 0..<2 { try await limiter.acquire(.interactive) }

        // Park a background waiter first, then an interactive waiter.
        let backgroundWaiterStarted = OrderLog()
        let backgroundTask = Task {
            await backgroundWaiterStarted.append("started")
            try await limiter.acquire(.background)
            await log.append("background")
        }
        while await backgroundWaiterStarted.entries.isEmpty {
            await Task.yield()
        }
        try await Task.sleep(for: .milliseconds(50))

        let interactiveWaiterStarted = OrderLog()
        let interactiveTask = Task {
            await interactiveWaiterStarted.append("started")
            try await limiter.acquire(.interactive)
            await log.append("interactive")
        }
        while await interactiveWaiterStarted.entries.isEmpty {
            await Task.yield()
        }
        try await Task.sleep(for: .milliseconds(50))

        #expect(await log.entries.isEmpty)

        // Release a single slot: the interactive waiter must resume first
        // even though the background waiter parked earlier.
        await limiter.release(.interactive)
        _ = try await interactiveTask.value

        #expect(await log.entries == ["interactive"])

        // Clean up the still-parked background waiter so the test doesn't
        // leak a task: release one of the four running background holders
        // (activeBackground drops below the cap) to let it through.
        await limiter.release(.background)
        _ = try await backgroundTask.value
        #expect(await log.entries == ["interactive", "background"])
    }
}

@Suite struct ProcessRunnerSafetyTests {
    @Test func cancelledWaiterIsRemovedWithoutWaitingForCapacity() async throws {
        let limiter = ConcurrencyLimiter(limit: 1)
        try await limiter.acquire(.interactive)
        let queued = Task { try await limiter.acquire(.interactive) }
        while await limiter.waitingCount == 0 { await Task.yield() }
        queued.cancel()
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while await limiter.waitingCount > 0 && ContinuousClock.now < deadline { await Task.yield() }
        #expect(await limiter.waitingCount == 0)
        await limiter.release(.interactive)
        await #expect(throws: CancellationError.self) { try await queued.value }
        // Cancelled waiters must not consume a future release.
        try await limiter.acquire(.interactive)
        await limiter.release(.interactive)
    }

    @Test func cancelledTaskNeverLaunchesCommand() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ProcessRunner.run("/usr/bin/touch", arguments: [marker.path])
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func cancellationTerminatesDescendantsHoldingPipes() async throws {
        let fixture = try ProcessTestFixture()
        defer { fixture.remove() }
        let completion = ProcessTestCompletion()
        let task = Task {
            try await completion.capture {
                try await ProcessRunner.run("/bin/sh", arguments: [
                    "-c", "(printf ready > \"$1\"; exec /bin/sleep 30) & wait", "job", fixture.ready.path
                ], timeout: .seconds(10))
            }
        }
        defer { task.cancel() }
        try await fixture.waitUntilReady(completion: completion)
        let began = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(began.duration(to: .now) < .seconds(2))
    }

    @Test func completedParentCannotLeavePipeHoldingChildren() async throws {
        let result = try await ProcessRunner.run("/bin/sh", arguments: ["-c", "sleep 5 & exit 0"], timeout: .seconds(4))
        #expect(try #require(result.executionDuration) < .seconds(2))
        #expect(result.exitCode == 0)
        #expect(!result.timedOut)
    }

    @Test func cancellationEscalatesForSigtermIgnoringJob() async throws {
        let fixture = try ProcessTestFixture()
        defer { fixture.remove() }
        let completion = ProcessTestCompletion()
        let task = Task {
            try await completion.capture {
                // Both the waiting shell and the descendant inherit ignored
                // SIGTERM before the descendant signals that it is ready.
                try await ProcessRunner.run("/bin/sh", arguments: [
                    "-c", "trap '' TERM; (printf ready > \"$1\"; exec /bin/sleep 30) & wait", "job", fixture.ready.path
                ], timeout: .seconds(10))
            }
        }
        defer { task.cancel() }
        try await fixture.waitUntilReady(completion: completion)
        let began = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(began.duration(to: .now) < .seconds(2))
    }

    @Test func stderrFloodIsBoundedAndStopsTheJob() async throws {
        let result = try await ProcessRunner.run("/bin/sh", arguments: ["-c", "yes x >&2"], maxOutputBytes: 1024, timeout: .seconds(2))
        #expect(result.outputTruncated)
        #expect(result.stdout.count + result.stderr.utf8.count <= 1024)
    }

    @Test func nonReadingStdinDoesNotPreventTimeout() async throws {
        let result = try await ProcessRunner.run("/bin/sleep", arguments: ["5"],
            timeout: .milliseconds(100), stdin: Data(repeating: 0, count: 8_000_000)
        )
        let elapsed = try #require(result.executionDuration)
        #expect(elapsed >= .milliseconds(100))
        #expect(elapsed < .seconds(2))
        #expect(result.timedOut)
    }

    @Test func cancellationStopsChildrenBeforeTheirSideEffects() async throws {
        let fixture = try ProcessTestFixture()
        defer { fixture.remove() }
        let completion = ProcessTestCompletion()
        let task = Task {
            try await completion.capture {
                try await ProcessRunner.run("/bin/sh", arguments: fixture.cancellationArguments, timeout: .seconds(10))
            }
        }
        defer { task.cancel() }
        try await fixture.waitUntilReady(completion: completion)
        try fixture.releaseChild()
        let began = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(began.duration(to: .now) < .seconds(2))
        try await Task.sleep(for: .milliseconds(1100))
        #expect(!FileManager.default.fileExists(atPath: fixture.late.path))
    }
}
