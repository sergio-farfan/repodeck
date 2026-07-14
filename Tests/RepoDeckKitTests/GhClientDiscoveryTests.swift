import Foundation
import Testing
@testable import RepoDeckKit

/// Isolated per-test temp directory, removed after the test regardless of
/// outcome — `discover(candidates:)` touches real paths on disk
/// (`FileManager.isExecutableFile`), so these tests avoid the real
/// `GhClient.defaultCandidates` locations (gh may or may not be installed
/// wherever this runs) in favor of files they fully control.
private func withTempDirectory<T>(_ body: (URL) throws -> T) rethrows -> T {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("GhClientDiscoveryTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    return try body(dir)
}

private func writeFile(at url: URL, executable: Bool) {
    FileManager.default.createFile(atPath: url.path, contents: Data("#!/bin/sh\n".utf8))
    let permissions: Int = executable ? 0o755 : 0o644
    try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
}

@Test func discoverReturnsClientForSoleExecutableCandidate() {
    withTempDirectory { dir in
        let ghPath = dir.appendingPathComponent("gh")
        writeFile(at: ghPath, executable: true)

        let client = GhClient.discover(candidates: [ghPath.path])

        #expect(client?.ghPath == ghPath.path)
    }
}

@Test func discoverReturnsNilWhenNoCandidateExists() {
    withTempDirectory { dir in
        let missing = dir.appendingPathComponent("gh-does-not-exist").path

        let client = GhClient.discover(candidates: [missing])

        #expect(client == nil)
    }
}

@Test func discoverReturnsNilWhenOnlyCandidateIsNotExecutable() {
    withTempDirectory { dir in
        let ghPath = dir.appendingPathComponent("gh")
        writeFile(at: ghPath, executable: false)

        let client = GhClient.discover(candidates: [ghPath.path])

        #expect(client == nil)
    }
}

@Test func discoverSkipsNonExecutableAndMissingCandidatesToFindLaterOne() {
    withTempDirectory { dir in
        let missing = dir.appendingPathComponent("gh-missing").path
        let nonExecutable = dir.appendingPathComponent("gh-not-executable")
        writeFile(at: nonExecutable, executable: false)
        let executable = dir.appendingPathComponent("gh-real")
        writeFile(at: executable, executable: true)

        let client = GhClient.discover(candidates: [missing, nonExecutable.path, executable.path])

        #expect(client?.ghPath == executable.path)
    }
}

@Test func discoverPrefersEarlierExecutableCandidateOverLaterOne() {
    withTempDirectory { dir in
        let first = dir.appendingPathComponent("gh-first")
        writeFile(at: first, executable: true)
        let second = dir.appendingPathComponent("gh-second")
        writeFile(at: second, executable: true)

        let client = GhClient.discover(candidates: [first.path, second.path])

        #expect(client?.ghPath == first.path)
    }
}

@Test func discoverReturnsNilForEmptyCandidateList() {
    let client = GhClient.discover(candidates: [])

    #expect(client == nil)
}
