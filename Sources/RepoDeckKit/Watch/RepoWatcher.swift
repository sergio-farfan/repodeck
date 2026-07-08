import CoreServices
import Dispatch
import Foundation

/// An event emitted by ``RepoWatcher`` after filtering and debouncing.
public enum WatchEvent: Sendable, Equatable {
    /// A known repo's contents changed. Carries the repo worktree root URL.
    case repoChanged(URL)
    /// A change occurred under a tracked root but outside every known repo.
    /// Carries the tracked root URL; the caller should rescan it.
    case possibleNewRepo(URL)
}

/// Watches tracked folders with FSEvents and emits debounced, filtered
/// ``WatchEvent`` values on a single-consumer ``AsyncStream``.
///
/// The class wraps the FSEvents C API, so it is `@unchecked Sendable`: every
/// piece of mutable state is confined to `queue`, a private serial dispatch
/// queue that also drives the FSEvent stream callbacks. Callers own the
/// lifecycle and should call ``stop()`` when finished; ``deinit`` is a
/// backstop that tears the streams down if they call did not.
public final class RepoWatcher: @unchecked Sendable {

    // MARK: Pruned directory names
    //
    // RepoScanner does not exist on this branch, so the pruned-names set is
    // defined locally per the task brief. The controller will reconcile this
    // with `RepoScanner.prunedNames` once both land on the integration branch.
    static let prunedNames: Set<String> = [
        "node_modules", "Pods", "DerivedData", "Carthage",
        "vendor", "__pycache__", "target", ".build",
    ]

    // MARK: Stored, immutable

    private let queue = DispatchQueue(label: "com.repodeck.RepoWatcher")
    private let stream: AsyncStream<WatchEvent>
    private let continuation: AsyncStream<WatchEvent>.Continuation

    // MARK: State (queue-confined)

    /// A normalized path string paired with the original URL to emit.
    private struct Entry {
        let key: String   // normalized absolute path, no trailing slash
        let url: URL      // original URL supplied by the caller
    }

    private var repoEntries: [Entry] = []
    private var rootEntries: [Entry] = []
    private var streamRefs: [FSEventStreamRef] = []
    private var debounce: [String: DispatchWorkItem] = [:]
    private var stopped = false

    private static let debounceInterval: DispatchTimeInterval = .milliseconds(300)
    private static let latency: CFTimeInterval = 0.2

    // MARK: Init

    public init() {
        var storedContinuation: AsyncStream<WatchEvent>.Continuation!
        self.stream = AsyncStream<WatchEvent>(bufferingPolicy: .unbounded) { continuation in
            storedContinuation = continuation
        }
        self.continuation = storedContinuation
    }

    deinit {
        // Backstop teardown. `stop()`'s work is idempotent via `stopped`.
        queue.sync { performStop() }
    }

    // MARK: Public API

    /// Replaces the watched configuration. `roots` are the tracked folders
    /// (one FSEventStream each); `repoPaths` are the currently-known repo
    /// worktree roots used for longest-prefix event mapping.
    public func setWatched(roots: [URL], repoPaths: [URL]) {
        let rootEntries = roots.map { Entry(key: Self.normalize($0), url: $0) }
        let repoEntries = repoPaths.map { Entry(key: Self.normalize($0), url: $0) }
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.reconfigure(rootEntries: rootEntries, repoEntries: repoEntries)
        }
    }

    /// Single-consumer stream of debounced events.
    public var events: AsyncStream<WatchEvent> { stream }

    /// Stops all watching and finishes the event stream.
    public func stop() {
        queue.sync { performStop() }
    }

    // MARK: Reconfigure / teardown (queue-confined)

    private func reconfigure(rootEntries: [Entry], repoEntries: [Entry]) {
        teardownStreams()
        // Longest key first so the first prefix match is the most specific
        // (handles nested repos and nested tracked roots).
        self.rootEntries = rootEntries.sorted { $0.key.count > $1.key.count }
        self.repoEntries = repoEntries.sorted { $0.key.count > $1.key.count }
        for entry in rootEntries {
            if let ref = makeStream(forRootPath: entry.key) {
                streamRefs.append(ref)
            }
        }
    }

    private func teardownStreams() {
        for ref in streamRefs {
            FSEventStreamStop(ref)
            FSEventStreamInvalidate(ref)
            FSEventStreamRelease(ref)
        }
        streamRefs.removeAll()
    }

    private func performStop() {
        guard !stopped else { return }
        stopped = true
        teardownStreams()
        for item in debounce.values { item.cancel() }
        debounce.removeAll()
        continuation.finish()
    }

    // MARK: FSEvents stream creation (queue-confined)

    private func makeStream(forRootPath rootPath: String) -> FSEventStreamRef? {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
        )
        guard let ref = FSEventStreamCreate(
            kCFAllocatorDefault,
            Self.callback,
            &context,
            [rootPath] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            Self.latency,
            flags
        ) else {
            return nil
        }
        FSEventStreamSetDispatchQueue(ref, queue)
        FSEventStreamStart(ref)
        return ref
    }

    /// C callback. Reconstructs `self` from the unretained `info` pointer and
    /// forwards paths. Runs on `queue` (set via `FSEventStreamSetDispatchQueue`),
    /// so state access inside ``handle(paths:)`` is already serialized.
    private static let callback: FSEventStreamCallback = { _, info, numEvents, eventPaths, _, _ in
        guard let info else { return }
        let watcher = Unmanaged<RepoWatcher>.fromOpaque(info).takeUnretainedValue()
        let cPaths = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
        var paths: [String] = []
        paths.reserveCapacity(numEvents)
        for i in 0..<numEvents {
            paths.append(String(cString: cPaths[i]))
        }
        watcher.handle(paths: paths)
    }

    // MARK: Event handling (queue-confined — called from `callback`)

    private func handle(paths: [String]) {
        guard !stopped else { return }
        for raw in paths {
            guard !Self.shouldIgnore(raw) else { continue }
            let path = Self.normalize(URL(fileURLWithPath: raw))

            if let repo = repoEntries.first(where: { Self.path(path, isUnderOrEqualTo: $0.key) }) {
                schedule(.repoChanged(repo.url), key: "R:" + repo.key)
            } else if let root = rootEntries.first(where: { Self.path(path, isUnderOrEqualTo: $0.key) }) {
                schedule(.possibleNewRepo(root.url), key: "N:" + root.key)
            }
        }
    }

    /// Trailing debounce: a burst for `key` collapses to one emission ~300 ms
    /// after the last event.
    private func schedule(_ event: WatchEvent, key: String) {
        debounce[key]?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.debounce[key] = nil
            guard !self.stopped else { return }
            self.continuation.yield(event)
        }
        debounce[key] = item
        queue.asyncAfter(deadline: .now() + Self.debounceInterval, execute: item)
    }

    // MARK: Filtering

    /// Drops FSEvents churn that must never trigger a refresh (from VS Code's
    /// git extension ignore list).
    static func shouldIgnore(_ rawPath: String) -> Bool {
        let components = rawPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)

        // `.git/index.lock` and `.git/worktrees/<x>/index.lock` churn.
        if components.last == "index.lock", components.contains(".git") {
            return true
        }
        for component in components {
            if component.contains(".watchman-cookie") { return true }
            if prunedNames.contains(component) { return true }
        }
        return false
    }

    // MARK: Path helpers

    /// Normalized absolute path: symlinks resolved (to match FSEvents' canonical
    /// reporting, e.g. `/var` -> `/private/var`) and standardized, no trailing slash.
    static func normalize(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// True when `candidate` equals `base` or sits below it at a path-component
    /// boundary (`/a/b` matches `/a/b/file` but not `/a/bc`). Inputs are
    /// normalized, trailing-slash-free absolute paths.
    static func path(_ candidate: String, isUnderOrEqualTo base: String) -> Bool {
        candidate == base || candidate.hasPrefix(base + "/")
    }
}
