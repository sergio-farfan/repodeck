import Foundation
import Testing
@testable import RepoDeckKit

/// Actor-backed collector for events observed off the watcher's AsyncStream.
private actor EventCollector {
    private(set) var events: [WatchEvent] = []

    func append(_ event: WatchEvent) {
        events.append(event)
    }

    func snapshot() -> [WatchEvent] {
        events
    }

    func clear() {
        events.removeAll()
    }
}

/// Test harness: a temp tree with one or more fake repos, a running watcher,
/// and a background task draining `events` into an `EventCollector`.
private final class WatchHarness: @unchecked Sendable {
    let root: URL
    let watcher: RepoWatcher
    let collector = EventCollector()
    private var drainTask: Task<Void, Never>?

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoWatcherTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // Resolve symlinks so paths match FSEvents' canonical reporting (/var -> /private/var).
        self.root = base.resolvingSymlinksInPath()
        self.watcher = RepoWatcher()
    }

    /// Create `root/<name>/.git/` plus a seed file, returning the repo root URL.
    @discardableResult
    func makeRepo(_ name: String) throws -> URL {
        let repo = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "seed".write(
            to: repo.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        return repo
    }

    /// Begin draining events into the collector.
    func startDraining() {
        let stream = watcher.events
        let collector = collector
        drainTask = Task {
            for await event in stream {
                await collector.append(event)
            }
        }
    }

    func write(_ contents: String, to url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    /// FSEvents' `sinceNow` granularity plus stream-start coalescing means the
    /// dir/file creations that built the fixture can leak through just after a
    /// stream starts. Wait for that initial flush to drain, then clear it, so a
    /// test observes only events caused by its own subsequent action.
    func settle() async {
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 s
        await collector.clear()
    }

    /// Poll until `predicate(events)` is true or `timeout` seconds elapse.
    /// Returns the final snapshot.
    func waitUntil(
        timeout: TimeInterval,
        _ predicate: @escaping @Sendable ([WatchEvent]) -> Bool
    ) async -> [WatchEvent] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let snapshot = await collector.snapshot()
            if predicate(snapshot) { return snapshot }
            try? await Task.sleep(nanoseconds: 50_000_000) // 50 ms
        }
        return await collector.snapshot()
    }

    func stop() {
        watcher.stop()
        drainTask?.cancel()
    }

    deinit {
        watcher.stop()
        drainTask?.cancel()
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite(.serialized)
struct RepoWatcherTests {

    // 1. Touch/modify a file in repoA -> receive .repoChanged(repoA) within timeout.
    @Test func fileChangeEmitsRepoChanged() async throws {
        let harness = try WatchHarness()
        let repoA = try harness.makeRepo("repoA")
        harness.watcher.setWatched(roots: [harness.root], repoPaths: [repoA])
        harness.startDraining()
        await harness.settle()

        try harness.write("hello", to: repoA.appendingPathComponent("file.txt"))

        let events = await harness.waitUntil(timeout: 5) { events in
            events.contains(.repoChanged(repoA))
        }
        #expect(events.contains(.repoChanged(repoA)))
        harness.stop()
    }

    // 2. Burst of 10 writes -> coalesced to far fewer than 10 (assert count <= 2).
    @Test func burstIsDebounced() async throws {
        let harness = try WatchHarness()
        let repoA = try harness.makeRepo("repoA")
        harness.watcher.setWatched(roots: [harness.root], repoPaths: [repoA])
        harness.startDraining()
        await harness.settle()

        for i in 0..<10 {
            try harness.write("v\(i)", to: repoA.appendingPathComponent("burst-\(i).txt"))
        }

        // Wait until at least one event lands, then let the debounce window settle.
        _ = await harness.waitUntil(timeout: 5) { !$0.isEmpty }
        try? await Task.sleep(nanoseconds: 1_000_000_000) // allow stragglers to coalesce

        let events = await harness.collector.snapshot()
        let repoChangedCount = events.filter { $0 == .repoChanged(repoA) }.count
        #expect(repoChangedCount >= 1)
        #expect(repoChangedCount <= 2)
        harness.stop()
    }

    // 3. Ignore filter: creating only .git/index.lock produces NO event within a short window.
    @Test func indexLockIsIgnored() async throws {
        let harness = try WatchHarness()
        let repoA = try harness.makeRepo("repoA")
        harness.watcher.setWatched(roots: [harness.root], repoPaths: [repoA])
        harness.startDraining()
        await harness.settle()

        // Write the lock file directly (not atomically) so no temporary
        // sibling file — which would NOT be ignored — is created alongside it.
        let lock = repoA.appendingPathComponent(".git/index.lock")
        #expect(FileManager.default.createFile(atPath: lock.path, contents: Data("locked".utf8)))

        // Poll for 1.5 s; the array must stay empty.
        let events = await harness.waitUntil(timeout: 1.5) { !$0.isEmpty }
        #expect(events.isEmpty)
        harness.stop()
    }

    // 4. New repo detection: a change outside all known repos -> .possibleNewRepo(root).
    @Test func changeOutsideKnownReposEmitsPossibleNewRepo() async throws {
        let harness = try WatchHarness()
        let repoA = try harness.makeRepo("repoA")
        harness.watcher.setWatched(roots: [harness.root], repoPaths: [repoA])
        harness.startDraining()
        await harness.settle()

        let newRepoDir = harness.root.appendingPathComponent("newRepo", isDirectory: true)
        try FileManager.default.createDirectory(at: newRepoDir, withIntermediateDirectories: true)
        try harness.write("new", to: newRepoDir.appendingPathComponent("somefile.txt"))

        let events = await harness.waitUntil(timeout: 5) { events in
            events.contains(.possibleNewRepo(harness.root))
        }
        #expect(events.contains(.possibleNewRepo(harness.root)))
        harness.stop()
    }

    // 5. stop() ends the stream (for-await loop terminates).
    @Test func stopFinishesStream() async throws {
        let harness = try WatchHarness()
        let repoA = try harness.makeRepo("repoA")
        harness.watcher.setWatched(roots: [harness.root], repoPaths: [repoA])

        let stream = harness.watcher.events
        let finished = Task { () -> Bool in
            for await _ in stream { }
            return true
        }

        // Give the stream a moment to be live, then stop.
        try? await Task.sleep(nanoseconds: 200_000_000)
        harness.watcher.stop()

        let terminated = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask { await finished.value }
            group.addTask {
                try await Task.sleep(nanoseconds: 3_000_000_000)
                return false
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
        #expect(terminated)
    }

    // 6. Reconfigure: adding repoB -> changes in repoB map to .repoChanged(repoB), not possibleNewRepo.
    @Test func reconfigureMapsNewRepo() async throws {
        let harness = try WatchHarness()
        let repoA = try harness.makeRepo("repoA")
        let repoB = try harness.makeRepo("repoB")

        harness.watcher.setWatched(roots: [harness.root], repoPaths: [repoA])
        harness.startDraining()

        // Reconfigure to include repoB before touching it, then let the
        // rebuilt stream's startup flush drain so we observe only repoB's change.
        harness.watcher.setWatched(roots: [harness.root], repoPaths: [repoA, repoB])
        await harness.settle()

        try harness.write("hi", to: repoB.appendingPathComponent("file.txt"))

        let events = await harness.waitUntil(timeout: 5) { events in
            events.contains(.repoChanged(repoB))
        }
        #expect(events.contains(.repoChanged(repoB)))
        #expect(!events.contains(.possibleNewRepo(harness.root)))
        harness.stop()
    }
}
