import Foundation
import Testing
@testable import RepoDeckKit

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
        let start = Date()
        let result = try await ProcessRunner.run(
            "/bin/sleep",
            arguments: ["30"],
            timeout: .milliseconds(200)
        )
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 5)
        #expect(result.timedOut == true)
        #expect(result.exitCode != 0)
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
            await limiter.acquire(.background)
        }

        // A fifth background acquire must park (activeBackground == backgroundLimit).
        let fifthBackgroundStarted = OrderLog()
        let fifthBackgroundAcquired = OrderLog()
        let fifthBackgroundTask = Task {
            await fifthBackgroundStarted.append("started")
            await limiter.acquire(.background)
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
        await limiter.acquire(.interactive)

        // The fifth background acquire is still parked — interactive slots
        // are independent of the background cap.
        #expect(await fifthBackgroundAcquired.entries.isEmpty)

        // Releasing one of the four running background slots must let the
        // parked background acquire through.
        await limiter.release(.background)
        _ = await fifthBackgroundTask.value
        #expect(await fifthBackgroundAcquired.entries == ["acquired"])
    }

    @Test func interactiveWaiterQueueJumpsAheadOfParkedBackgroundWaiter() async throws {
        let limiter = ConcurrencyLimiter(limit: 6)
        let log = OrderLog()

        // Fill all six slots with a mix of tiers.
        for _ in 0..<4 { await limiter.acquire(.background) }
        for _ in 0..<2 { await limiter.acquire(.interactive) }

        // Park a background waiter first, then an interactive waiter.
        let backgroundWaiterStarted = OrderLog()
        let backgroundTask = Task {
            await backgroundWaiterStarted.append("started")
            await limiter.acquire(.background)
            await log.append("background")
        }
        while await backgroundWaiterStarted.entries.isEmpty {
            await Task.yield()
        }
        try await Task.sleep(for: .milliseconds(50))

        let interactiveWaiterStarted = OrderLog()
        let interactiveTask = Task {
            await interactiveWaiterStarted.append("started")
            await limiter.acquire(.interactive)
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
        _ = await interactiveTask.value

        #expect(await log.entries == ["interactive"])

        // Clean up the still-parked background waiter so the test doesn't
        // leak a task: release one of the four running background holders
        // (activeBackground drops below the cap) to let it through.
        await limiter.release(.background)
        _ = await backgroundTask.value
        #expect(await log.entries == ["interactive", "background"])
    }
}
