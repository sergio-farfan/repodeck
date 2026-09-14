import Darwin
import Foundation
import Synchronization

public enum SubprocessPriority: Sendable {
    case interactive
    case background
}

public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: String
    public let outputTruncated: Bool
    public let timedOut: Bool
    /// Internal diagnostics exclude limiter admission and Swift task resumption.
    /// Populated only by a real subprocess, from successful spawn through reaping.
    var executionDuration: Duration?

    public init(exitCode: Int32, stdout: Data, stderr: String, outputTruncated: Bool, timedOut: Bool = false) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.outputTruncated = outputTruncated
        self.timedOut = timedOut
        self.executionDuration = nil
    }
}

public struct ProcessOutputLimitError: Error, LocalizedError, Sendable {
    public var errorDescription: String? { "Command output exceeded its limit. The command was stopped." }
    public init() {}
}

public enum CommandStream: Sendable { case stdout, stderr }
public enum CommandEvent: Sendable {
    case output(stream: CommandStream, text: String)
    case exit(code: Int32)
}

/// A streamed job has a separate cleanup lifetime from its event consumer.
/// Cancellation ends an AsyncThrowingStream iterator immediately, so callers
/// holding resources must await completion before releasing those resources.
public struct StreamingProcess: Sendable {
    public let events: AsyncThrowingStream<CommandEvent, Error>
    private let producer: Task<Void, Never>
    private let stop: @Sendable () -> Void

    fileprivate init(events: AsyncThrowingStream<CommandEvent, Error>, producer: Task<Void, Never>,
                     stop: @escaping @Sendable () -> Void) {
        self.events = events
        self.producer = producer
        self.stop = stop
    }

    public func cancel() { stop() }

    /// Waits for the process group to be stopped and reaped even when the
    /// waiting task has already been cancelled.
    public func waitForCompletion() async { await producer.value }
}

/// Runs each command in its own process group. Cancellation and limits stop the
/// whole job, including children holding pipes open. No shell is added implicitly.
public enum ProcessRunner {
    static let concurrencyLimit = 6
    static let limiter = ConcurrencyLimiter(limit: concurrencyLimit)
    public static let defaultOutputLimit = 16 * 1024 * 1024

    public static func run(
        _ executable: String = GitDefaults.gitPath,
        arguments: [String],
        workingDirectory: URL? = nil,
        environment: [String: String] = [:],
        maxOutputBytes: Int? = nil,
        priority: SubprocessPriority = .interactive,
        timeout: Duration? = nil,
        stdin: Data? = nil
    ) async throws -> ProcessResult {
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["LC_ALL"] = "C"
        env.merge(environment) { _, override in override }
        return try await execute(
            executable, arguments: arguments, directory: workingDirectory?.path, environment: env,
            limit: max(0, maxOutputBytes ?? defaultOutputLimit), priority: priority, timeout: timeout,
            input: stdin, control: ProcessControl(), receive: nil
        )
    }

    /// Streams at most 16 MiB per command by default. Both the pipe reader and
    /// delivery queue are bounded; a slow consumer receives a limit error rather
    /// than silently losing output. Standard input is closed (not an interactive terminal).
    public static func runStreaming(
        _ executable: String,
        arguments: [String],
        workingDirectory: URL? = nil,
        environment: [String: String] = [:],
        priority: SubprocessPriority = .interactive,
        maxOutputBytes: Int = defaultOutputLimit,
        timeout: Duration? = nil
    ) -> AsyncThrowingStream<CommandEvent, Error> {
        startStreaming(executable, arguments: arguments, workingDirectory: workingDirectory,
                       environment: environment, priority: priority, maxOutputBytes: maxOutputBytes,
                       timeout: timeout).events
    }

    /// Use this handle when job cleanup must finish before releasing a lock or
    /// reporting the surrounding operation as idle.
    public static func startStreaming(
        _ executable: String,
        arguments: [String],
        workingDirectory: URL? = nil,
        environment: [String: String] = [:],
        priority: SubprocessPriority = .interactive,
        maxOutputBytes: Int = defaultOutputLimit,
        timeout: Duration? = nil
    ) -> StreamingProcess {
        let (events, continuation) = AsyncThrowingStream<CommandEvent, Error>.makeStream(bufferingPolicy: .bufferingOldest(64))
        let control = ProcessControl()
        let producer = Task {
            var env = ProcessInfo.processInfo.environment
            env.merge(environment) { _, override in override }
            do {
                let result = try await execute(
                    executable, arguments: arguments, directory: workingDirectory?.path, environment: env,
                    limit: max(0, maxOutputBytes), priority: priority, timeout: timeout, input: nil,
                    control: control
                ) { event in
                    switch continuation.yield(event) {
                    case .dropped: control.limitOutput()
                    case .terminated: control.cancel()
                    case .enqueued: break
                    @unknown default: control.cancel()
                    }
                }
                if result.outputTruncated { throw ProcessOutputLimitError() }
                // Preserve a terminal event even when the consumer has just
                // filled the queue; an overflow is an explicit failure.
                if case .dropped = continuation.yield(.exit(code: result.exitCode)) {
                    throw ProcessOutputLimitError()
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in
            control.cancel()
            producer.cancel()
        }
        return StreamingProcess(events: events, producer: producer) {
            control.cancel()
            producer.cancel()
        }
    }

    private static func execute(
        _ executable: String, arguments: [String], directory: String?, environment: [String: String],
        limit: Int, priority: SubprocessPriority, timeout: Duration?, input: Data?, control: ProcessControl,
        receive: (@Sendable (CommandEvent) -> Void)?
    ) async throws -> ProcessResult {
        try await limiter.acquire(priority)
        do {
            try Task.checkCancellation()
            let result = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
                    // poll/waitpid are blocking APIs. Keep them off Swift's
                    // cooperative executor; the limiter bounds these workers.
                    DispatchQueue.global(qos: priority == .background ? .utility : .userInitiated).async {
                        do {
                            let result = try runJob(executable, arguments: arguments, directory: directory,
                                                    environment: environment, limit: limit, timeout: timeout,
                                                    input: input, control: control, receive: receive)
                            continuation.resume(returning: result)
                        } catch { continuation.resume(throwing: error) }
                    }
                }
            } onCancel: {
                control.cancel()
            }
            try Task.checkCancellation()
            await limiter.release(priority)
            return result
        } catch {
            await limiter.release(priority)
            throw error
        }
    }
}

/// Cancellation can arrive before the worker starts. The spawn and cancellation
/// flag share a lock so an already-cancelled job never launches after waiting.
private final class ProcessControl: Sendable {
    struct State { var cancelled = false; var outputLimited = false }
    let state = Mutex(State())
    func cancel() { state.withLock { $0.cancelled = true } }
    func limitOutput() { state.withLock { $0.outputLimited = true } }
}

/// Blocking POSIX work lives only on a dispatch worker; no descriptors, pointers,
/// or mutable Foundation Process objects cross an isolation boundary.
private func runJob(
    _ executable: String, arguments: [String], directory: String?, environment: [String: String],
    limit: Int, timeout: Duration?, input: Data?, control: ProcessControl,
    receive: (@Sendable (CommandEvent) -> Void)?
) throws -> ProcessResult {
    var descriptors: [Int32] = []
    defer { for fd in descriptors where fd >= 0 { Darwin.close(fd) } }
    func makePipe() throws -> (Int32, Int32) {
        var pair: [Int32] = [-1, -1]
        guard pipe(&pair) == 0 else { throw posixError(errno) }
        descriptors.append(contentsOf: pair)
        for fd in pair { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        return (pair[0], pair[1])
    }
    func closeFD(_ fd: inout Int32) {
        guard fd >= 0 else { return }
        Darwin.close(fd)
        if let index = descriptors.firstIndex(of: fd) { descriptors[index] = -1 }
        fd = -1
    }
    let out = try makePipe()
    let err = try makePipe()
    var outputFD = out.0, errorFD = err.0
    let inputPipe = try input.map { _ in try makePipe() }
    var inputFD = inputPipe?.1 ?? -1
    let nullFD = open("/dev/null", O_RDONLY | O_CLOEXEC)
    guard nullFD >= 0 else { throw posixError(errno) }
    descriptors.append(nullFD)

    var actions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    try checkPOSIX(posix_spawn_file_actions_init(&actions))
    defer { posix_spawn_file_actions_destroy(&actions) }
    try checkPOSIX(posix_spawnattr_init(&attributes))
    defer { posix_spawnattr_destroy(&attributes) }
    try checkPOSIX(posix_spawn_file_actions_adddup2(&actions, inputPipe?.0 ?? nullFD, STDIN_FILENO))
    try checkPOSIX(posix_spawn_file_actions_adddup2(&actions, out.1, STDOUT_FILENO))
    try checkPOSIX(posix_spawn_file_actions_adddup2(&actions, err.1, STDERR_FILENO))
    for fd in descriptors { try checkPOSIX(posix_spawn_file_actions_addclose(&actions, fd)) }
    if let directory { try checkPOSIX(posix_spawn_file_actions_addchdir_np(&actions, directory)) }
    try checkPOSIX(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)))
    try checkPOSIX(posix_spawnattr_setpgroup(&attributes, 0))
    var mask = sigset_t(0)
    sigemptyset(&mask)
    try checkPOSIX(posix_spawnattr_setsigmask(&attributes, &mask))
    var defaults = sigset_t(0)
    sigemptyset(&defaults)
    sigaddset(&defaults, SIGTERM)
    sigaddset(&defaults, SIGPIPE)
    try checkPOSIX(posix_spawnattr_setsigdefault(&attributes, &defaults))

    let argv = ([executable] + arguments).map { strdup($0) } + [nil]
    let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer {
        for pointer in argv { free(pointer) }
        for pointer in envp { free(pointer) }
    }
    var pid: pid_t = 0
    try control.state.withLock { state in
        if state.cancelled { throw CancellationError() }
        try argv.withUnsafeBufferPointer { argv in
            try envp.withUnsafeBufferPointer { envp in
                try checkPOSIX(posix_spawn(&pid, executable, &actions, &attributes,
                                          UnsafeMutablePointer(mutating: argv.baseAddress!),
                                          UnsafeMutablePointer(mutating: envp.baseAddress!)))
            }
        }
    }
    let launched = ContinuousClock.now
    // Parent never retains the write ends of the child's output pipes.
    for fd in [out.1, err.1, inputPipe?.0 ?? nullFD] {
        var fd = fd
        closeFD(&fd)
    }
    for fd in [outputFD, errorFD, inputFD] where fd >= 0 {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    }
    if inputFD >= 0 { _ = fcntl(inputFD, F_SETNOSIGPIPE, 1) }

    let started = ContinuousClock.now
    let deadline = timeout.map { started.advanced(by: $0) }
    var stoppingAt: ContinuousClock.Instant?
    var sentKill = false
    var childExit: Int32?
    var timedOut = false
    var truncated = false
    var stdout = Data(), stderr = Data()
    var captured = 0, inputOffset = 0
    var outDecoder = StreamTextDecoder(), errDecoder = StreamTextDecoder()
    var buffer = [UInt8](repeating: 0, count: 32 * 1024)

    func beginStopping() {
        guard stoppingAt == nil else { return }
        stoppingAt = .now
        kill(-pid, SIGTERM)
        closeFD(&inputFD)
    }
    // WNOWAIT retains the leader until group cleanup finishes, preventing pid /
    // process-group ID reuse while we still need to signal descendants.
    func inspectExit() {
        guard childExit == nil else { return }
        var info = siginfo_t()
        if waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0, info.si_pid == pid {
            childExit = info.si_status
        }
    }
    func readOutput(_ fd: inout Int32, stream: CommandStream, decoder: inout StreamTextDecoder, data: inout Data) {
        guard fd >= 0 else { return }
        for _ in 0..<16 {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { closeFD(&fd); break }
            if count < 0 {
                if errno != EAGAIN && errno != EINTR { closeFD(&fd) }
                break
            }
            let accepted = min(count, max(0, limit - captured))
            if accepted > 0 {
                let bytes = Data(buffer.prefix(accepted))
                captured += accepted
                if let receive {
                    let text = decoder.append(bytes)
                    if !text.isEmpty { receive(.output(stream: stream, text: text)) }
                } else { data.append(bytes) }
            }
            if accepted < count { truncated = true; beginStopping() }
        }
        if fd < 0, let receive {
            let tail = decoder.finish()
            if !tail.isEmpty { receive(.output(stream: stream, text: tail)) }
        }
    }

    while true {
        let state = control.state.withLock { $0 }
        if state.cancelled { beginStopping() }
        if state.outputLimited { truncated = true; beginStopping() }
        if let deadline, ContinuousClock.now >= deadline, stoppingAt == nil {
            timedOut = true
            beginStopping()
        }
        readOutput(&outputFD, stream: .stdout, decoder: &outDecoder, data: &stdout)
        readOutput(&errorFD, stream: .stderr, decoder: &errDecoder, data: &stderr)
        if inputFD >= 0, let input {
            if inputOffset == input.count { closeFD(&inputFD) }
            else {
                let written = input.withUnsafeBytes { bytes in
                    Darwin.write(inputFD, bytes.baseAddress!.advanced(by: inputOffset), min(32 * 1024, input.count - inputOffset))
                }
                if written > 0 { inputOffset += written }
                else if written < 0 && errno != EAGAIN && errno != EINTR { closeFD(&inputFD) }
            }
        }
        inspectExit()
        // A completed command owns its background children too. Shut them down
        // before returning, even if they inherited or redirected the job's pipes.
        if childExit != nil {
            if outputFD < 0 && errorFD < 0 { break }
            beginStopping()
        }
        if let stoppingAt {
            let elapsed = stoppingAt.duration(to: .now)
            if elapsed >= .milliseconds(500), !sentKill { kill(-pid, SIGKILL); sentKill = true }
            if elapsed >= .seconds(1) {
                closeFD(&outputFD)
                closeFD(&errorFD)
                // An escaped descendant cannot hold the caller's pipes open.
                if childExit != nil { break }
            }
        }
        var polls = [pollfd]()
        if outputFD >= 0 { polls.append(pollfd(fd: outputFD, events: Int16(POLLIN), revents: 0)) }
        if errorFD >= 0 { polls.append(pollfd(fd: errorFD, events: Int16(POLLIN), revents: 0)) }
        if inputFD >= 0 { polls.append(pollfd(fd: inputFD, events: Int16(POLLOUT), revents: 0)) }
        _ = poll(&polls, nfds_t(polls.count), 20)
    }
    kill(-pid, SIGKILL)
    var status: Int32 = 0
    while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
    let reaped = ContinuousClock.now
    if control.state.withLock({ $0.cancelled }) { throw CancellationError() }
    var result = ProcessResult(exitCode: childExit ?? 0, stdout: stdout, stderr: String(decoding: stderr, as: UTF8.self),
                               outputTruncated: truncated || control.state.withLock { $0.outputLimited }, timedOut: timedOut)
    result.executionDuration = launched.duration(to: reaped)
    return result
}

private func posixError(_ code: Int32) -> POSIXError { POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
private func checkPOSIX(_ code: Int32) throws { if code != 0 { throw posixError(code) } }

/// Keep incomplete UTF-8 scalars between reads instead of replacing a split
/// multibyte character with replacement glyphs at arbitrary pipe boundaries.
private struct StreamTextDecoder {
    var pending = Data()
    mutating func append(_ bytes: Data) -> String {
        pending.append(bytes)
        var prefixCount = pending.count
        let values = Array(pending.suffix(4))
        for index in values.indices.reversed() {
            let value = values[index]
            if value & 0xc0 == 0x80 { continue }
            let needed = value >= 0xf0 && value <= 0xf4 ? 4 : value >= 0xe0 && value <= 0xef ? 3 : value >= 0xc2 && value <= 0xdf ? 2 : 1
            let present = values.count - index
            if present < needed { prefixCount -= present }
            break
        }
        let result = String(decoding: pending.prefix(prefixCount), as: UTF8.self)
        pending.removeFirst(prefixCount)
        return result
    }
    mutating func finish() -> String {
        defer { pending.removeAll() }
        return String(decoding: pending, as: UTF8.self)
    }
}

actor ConcurrencyLimiter {
    private struct Waiter { let id: UUID; let continuation: CheckedContinuation<Void, Error> }
    private let limit: Int
    private let backgroundLimit: Int
    private var available: Int
    private var interactiveWaiters: [Waiter] = []
    private var backgroundWaiters: [Waiter] = []
    private var activeBackground = 0
    var waitingCount: Int { interactiveWaiters.count + backgroundWaiters.count }

    init(limit: Int, backgroundLimit: Int = 4) {
        self.limit = limit
        self.backgroundLimit = min(limit, backgroundLimit)
        self.available = limit
    }

    func acquire(_ priority: SubprocessPriority) async throws {
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                if available > 0 && (priority == .interactive || activeBackground < backgroundLimit) {
                    available -= 1
                    if priority == .background { activeBackground += 1 }
                    continuation.resume()
                } else {
                    let waiter = Waiter(id: id, continuation: continuation)
                    if priority == .interactive { interactiveWaiters.append(waiter) }
                    else { backgroundWaiters.append(waiter) }
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        if let index = interactiveWaiters.firstIndex(where: { $0.id == id }) {
            interactiveWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
        } else if let index = backgroundWaiters.firstIndex(where: { $0.id == id }) {
            backgroundWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
        }
    }

    func release(_ priority: SubprocessPriority) {
        if priority == .background { activeBackground -= 1 }
        if !interactiveWaiters.isEmpty { interactiveWaiters.removeFirst().continuation.resume() }
        else if !backgroundWaiters.isEmpty && activeBackground < backgroundLimit {
            activeBackground += 1
            backgroundWaiters.removeFirst().continuation.resume()
        } else { available = min(available + 1, limit) }
    }
}
