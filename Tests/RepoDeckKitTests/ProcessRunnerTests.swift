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
}
