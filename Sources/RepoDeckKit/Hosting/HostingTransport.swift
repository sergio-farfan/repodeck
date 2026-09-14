import Foundation

public struct HostingCommand: Sendable {
    public let executable: String
    public let arguments: [String]
    public let directory: URL
    public let environment: [String: String]
    public let input: Data?
}
public typealias HostingCommandRunner = @Sendable (HostingCommand) async throws -> ProcessResult

/// JSON travels between async operations as a Sendable value, never [String: Any].
indirect enum HostingJSON: Codable, Sendable {
    case object([String: HostingJSON]), array([HostingJSON]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([HostingJSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: HostingJSON].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    subscript(_ key: String) -> HostingJSON { if case .object(let d) = self { return d[key] ?? .null }; return .null }
    var string: String? { if case .string(let s) = self { return s }; return nil }
    var text: String { string ?? "" }
    var int: Int? { if case .number(let n) = self, n.isFinite, n >= 0, n < Double(Int.max) { return Int(n) }; return nil }
    var bool: Bool { if case .bool(let b) = self { return b }; return false }
    var array: [HostingJSON] { if case .array(let a) = self { return a }; return [] }
}

struct HostingTransport: Sendable {
    let repository: HostingRepository
    let cliPath: String
    let directory: URL
    let runner: HostingCommandRunner
    static let live: HostingCommandRunner = { command in
        try await ProcessRunner.run(command.executable, arguments: command.arguments,
            workingDirectory: command.directory, environment: command.environment,
            maxOutputBytes: 12_000_000, priority: .interactive, timeout: .seconds(45), stdin: command.input)
    }
    func api(_ endpoint: String, method: String = "GET", body: [String: HostingJSON]? = nil) async throws -> HostingJSON {
        var arguments = ["api", "--hostname", repository.host, "--method", method, endpoint]
        let input = try body.map { try JSONEncoder().encode(HostingJSON.object($0)) }
        if input != nil { arguments += ["--input", "-"] }
        let result = try await runner(HostingCommand(executable: cliPath, arguments: arguments, directory: directory,
            environment: ["GH_PROMPT_DISABLED": "1", "GH_NO_UPDATE_NOTIFIER": "1", "GLAB_CHECK_UPDATE": "false",
                "GITLAB_HOST": repository.host, "GH_HOST": repository.host, "NO_COLOR": "1"], input: input))
        guard !result.timedOut else { throw HostingError.unavailable("\(repository.host) timed out.") }
        guard !result.outputTruncated else { throw HostingError.invalidResponse("The server response exceeded the read limit; refresh a smaller result set.") }
        guard result.exitCode == 0 else {
            // CLI diagnostics can contain URLs with credentials; omit raw argv/input and redact URL passwords.
            let message = String(result.stderr.prefix(2000)).replacingOccurrences(
                of: #"(https?://)[^\s/@]+:[^\s/@]+@"#, with: "$1[redacted]@", options: .regularExpression)
            throw HostingError.unavailable("\(repository.host): \(message.isEmpty ? "CLI request failed (\(result.exitCode))." : message)")
        }
        if result.stdout.isEmpty { return .null }
        do { return try JSONDecoder().decode(HostingJSON.self, from: result.stdout) }
        catch { throw HostingError.invalidResponse("\(repository.host) returned an unreadable response.") }
    }
    func objectPages(_ endpoint: String, key: String) async throws -> [HostingJSON] {
        var result: [HostingJSON] = []
        for page in 1...100 {
            let separator = endpoint.contains("?") ? "&" : "?"
            let response = try await api("\(endpoint)\(separator)per_page=100&page=\(page)")
            guard case .array(let items) = response[key] else { throw HostingError.invalidResponse("Expected the hosting service's \(key) list.") }
            result += items
            if items.count < 100 { return result }
        }
        throw HostingError.invalidResponse("The hosting service's \(key) list exceeded the complete-read limit.")
    }
    func pages(_ endpoint: String) async throws -> [HostingJSON] {
        var result: [HostingJSON] = []
        for page in 1...100 {
            let separator = endpoint.contains("?") ? "&" : "?"
            let value = try await api("\(endpoint)\(separator)per_page=100&page=\(page)")
            guard case .array(let items) = value else { throw HostingError.invalidResponse("Expected a paginated server list.") }
            result += items
            if items.count < 100 { return result }
        }
        throw HostingError.invalidResponse("The server list is too large to inspect completely. Narrow the request in the hosting service.")
    }
}

func hostingEncode(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? ""
}
