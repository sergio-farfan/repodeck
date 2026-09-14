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
        let fixture = try ProcessTestFixture()
        defer { fixture.remove() }
        let job = ProcessRunner.startStreaming(
            "/bin/sh", arguments: ["-c", "printf ready > \"$1\"; exec /bin/sleep 30", "job", fixture.ready.path],
            timeout: .seconds(10)
        )
        let completion = ProcessTestCompletion()
        let consumer = Task {
            try await completion.capture {
                for try await _ in job.events { }
            }
        }
        defer { consumer.cancel(); job.cancel() }
        try await fixture.waitUntilReady(completion: completion)
        let began = ContinuousClock.now
        consumer.cancel()
        _ = await consumer.result
        // Ending iteration alone does not prove that the producer reaped the
        // running process. Bound its cleanup as well as the consumer's exit.
        await job.waitForCompletion()
        #expect(began.duration(to: .now) < .seconds(2))
    }

    @Test func nonexistentExecutableThrows() async {
        await #expect(throws: (any Error).self) {
            for try await _ in ProcessRunner.runStreaming("/nonexistent/path/to/binary", arguments: []) {}
        }
    }
}

@Suite struct ProcessRunnerStreamingSafetyTests {
    @Test func utf8CharactersSurviveSeparatePipeWrites() async throws {
        var output = ""
        for try await event in ProcessRunner.runStreaming("/bin/sh", arguments: ["-c", "printf '\\360\\237'; sleep 0.05; printf '\\230\\200\\n'"]) {
            if case .output(.stdout, let text) = event { output += text }
        }
        #expect(output == "😀\n")
    }

    @Test func outputLimitProducesExplicitError() async throws {
        var count = 0
        do {
            for try await event in ProcessRunner.runStreaming("/bin/sh", arguments: ["-c", "yes x >&2"], maxOutputBytes: 1024) {
                if case .output(_, let text) = event { count += text.utf8.count }
            }
            Issue.record("Expected an output limit error")
        } catch is ProcessOutputLimitError { }
        #expect(count <= 1024)
    }

    @Test func cancelledStreamingJobCannotLeaveChildrenRunning() async throws {
        let fixture = try ProcessTestFixture()
        defer { fixture.remove() }
        let job = ProcessRunner.startStreaming("/bin/sh", arguments: fixture.cancellationArguments, timeout: .seconds(10))
        let completion = ProcessTestCompletion()
        let consumer = Task {
            try await completion.capture {
                for try await _ in job.events { }
            }
        }
        defer { consumer.cancel(); job.cancel() }
        try await fixture.waitUntilReady(completion: completion)
        try fixture.releaseChild()
        let began = ContinuousClock.now
        consumer.cancel()
        _ = await consumer.result
        await job.waitForCompletion()
        #expect(began.duration(to: .now) < .seconds(2))
        try await Task.sleep(for: .milliseconds(1100))
        #expect(!FileManager.default.fileExists(atPath: fixture.late.path))
    }
}
