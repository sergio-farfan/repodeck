import Foundation
import Testing
@testable import RepoDeckKit

@Suite struct ProcessRunnerStreamingTests {
    @Test func stdoutEventsAccumulateAndExitCodeIsZero() async throws {
        var stdout = ""
        var exitCode: Int32?
        for try await event in ProcessRunner.runStreaming("/bin/sh", arguments: ["-c", "echo hi"]) {
            switch event {
            case .output(.stdout, let text): stdout += text
            case .output(.stderr, _): break
            case .exit(let code): exitCode = code
            }
        }
        #expect(stdout.contains("hi"))
        #expect(exitCode == 0)
    }

    @Test func stderrEventsAreTagged() async throws {
        var stderr = ""
        var exitCode: Int32?
        for try await event in ProcessRunner.runStreaming("/bin/sh", arguments: ["-c", "echo oops >&2"]) {
            switch event {
            case .output(.stderr, let text): stderr += text
            case .output(.stdout, _): break
            case .exit(let code): exitCode = code
            }
        }
        #expect(stderr.contains("oops"))
        #expect(exitCode == 0)
    }

    @Test func exitCodePropagates() async throws {
        var exitCode: Int32?
        for try await event in ProcessRunner.runStreaming("/bin/sh", arguments: ["-c", "exit 7"]) {
            if case .exit(let code) = event { exitCode = code }
        }
        #expect(exitCode == 7)
    }

    @Test func interleavedStdoutAndStderrBothCaptured() async throws {
        var stdout = ""
        var stderr = ""
        var exitCode: Int32?
        for try await event in ProcessRunner.runStreaming(
            "/bin/sh",
            arguments: ["-c", "echo a; echo b >&2; echo c"]
        ) {
            switch event {
            case .output(.stdout, let text): stdout += text
            case .output(.stderr, let text): stderr += text
            case .exit(let code): exitCode = code
            }
        }
        #expect(stdout.contains("a"))
        #expect(stdout.contains("c"))
        #expect(stderr.contains("b"))
        #expect(exitCode == 0)
    }

    @Test func cancellationTerminatesPromptlyWithoutHanging() async throws {
        let consumer = Task {
            for try await _ in ProcessRunner.runStreaming("/bin/sh", arguments: ["-c", "sleep 30"]) {
                // Just drain; the assertion is about how fast this loop ends.
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        consumer.cancel()

        // Timeout guard: a cancellation-handling bug must not hang the suite.
        let timedOut = await raced(against: .seconds(5)) {
            _ = await consumer.result
        }
        #expect(timedOut == false)
    }

    @Test func nonexistentExecutableThrows() async {
        await #expect(throws: (any Error).self) {
            for try await _ in ProcessRunner.runStreaming("/nonexistent/path/to/binary", arguments: []) {}
        }
    }
}

/// Runs `operation`, racing it against a timeout. Returns `true` if the
/// timeout elapsed first (i.e. `operation` did not finish in time), `false`
/// if `operation` completed first. Used to keep a cancellation bug from
/// hanging the test suite.
private func raced(against timeout: Duration, _ operation: @escaping @Sendable () async -> Void) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            await operation()
            return false
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return true
        }
        let firstResult = await group.next()!
        group.cancelAll()
        return firstResult
    }
}
