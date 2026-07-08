import Foundation

/// Pure parser for `git status --porcelain=v2 --branch -z` output.
/// No `Process`, no I/O — plain functions over `Data`/`String` so it is
/// unit-testable without invoking git.
public enum PorcelainParser {
    /// Parses `git status --porcelain=v2 --branch -z` output (NUL-separated records).
    /// `truncated` marks output cut off mid-stream (huge repo) — the trailing partial
    /// record is dropped and the result's `didHitLimit` is set.
    public static func parse(_ output: Data, truncated: Bool = false) -> RepoStatus {
        var rawRecords = output.split(separator: 0x00, omittingEmptySubsequences: true)
        var didHitLimit = false
        if truncated, !rawRecords.isEmpty {
            rawRecords.removeLast()
            didHitLimit = true
        }
        let records = rawRecords.map { String(decoding: $0, as: UTF8.self) }
        return parseRecords(records, didHitLimit: didHitLimit)
    }

    /// Convenience for tests: joins on NUL.
    public static func parse(_ records: [String], truncated: Bool = false) -> RepoStatus {
        let joined = records.joined(separator: "\u{0}")
        return parse(Data(joined.utf8), truncated: truncated)
    }

    // MARK: - Record dispatch

    private static func parseRecords(_ records: [String], didHitLimit: Bool) -> RepoStatus {
        var status = RepoStatus(didHitLimit: didHitLimit)
        var changes: [FileChange] = []
        var index = 0
        while index < records.count {
            let record = records[index]
            guard let kind = record.first else {
                index += 1
                continue
            }
            switch kind {
            case "#":
                parseBranchHeader(record, into: &status)
                index += 1
            case "1":
                parseOrdinaryChange(record, into: &changes)
                index += 1
            case "2":
                let originalPath = index + 1 < records.count ? records[index + 1] : nil
                parseRenameOrCopy(record, originalPath: originalPath, into: &changes)
                index += originalPath != nil ? 2 : 1
            case "u":
                parseUnmergedChange(record, into: &changes)
                index += 1
            case "?":
                parseUntracked(record, into: &changes)
                index += 1
            case "!":
                // Ignored entries are intentionally dropped.
                index += 1
            default:
                // Unknown record kind: skip for forward compatibility.
                index += 1
            }
        }
        status.changes = changes
        return status
    }

    // MARK: - Branch headers

    private static func parseBranchHeader(_ record: String, into status: inout RepoStatus) {
        if let oid = value(after: "# branch.oid ", in: record) {
            status.oid = oid
        } else if let head = value(after: "# branch.head ", in: record) {
            status.branch = head
        } else if let upstream = value(after: "# branch.upstream ", in: record) {
            status.upstream = upstream
        } else if let ab = value(after: "# branch.ab ", in: record) {
            for token in ab.split(separator: " ") {
                if token.hasPrefix("+") {
                    status.ahead = Int(token.dropFirst())
                } else if token.hasPrefix("-") {
                    status.behind = Int(token.dropFirst())
                }
            }
        }
        // Any other "#" record is skipped for forward compatibility.
    }

    private static func value(after prefix: String, in record: String) -> String? {
        guard record.hasPrefix(prefix) else { return nil }
        return String(record.dropFirst(prefix.count))
    }

    // MARK: - Change records

    private static func parseOrdinaryChange(_ record: String, into changes: inout [FileChange]) {
        let fields = record.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
        guard fields.count == 9 else { return }
        appendFanOut(xy: fields[1], path: String(fields[8]), originalPath: nil, into: &changes)
    }

    private static func parseRenameOrCopy(_ record: String, originalPath: String?, into changes: inout [FileChange]) {
        let fields = record.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
        guard fields.count == 10 else { return }
        appendFanOut(xy: fields[1], path: String(fields[9]), originalPath: originalPath, into: &changes)
    }

    private static func parseUnmergedChange(_ record: String, into changes: inout [FileChange]) {
        let fields = record.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
        guard fields.count == 11 else { return }
        changes.append(FileChange(path: String(fields[10]), area: .unmerged, statusLetter: String(fields[1])))
    }

    private static func parseUntracked(_ record: String, into changes: inout [FileChange]) {
        guard record.count > 2 else { return }
        let path = String(record.dropFirst(2)) // drop "? "
        changes.append(FileChange(path: path, area: .untracked, statusLetter: "U"))
    }

    // MARK: - XY fan-out

    private static func appendFanOut(xy: Substring, path: String, originalPath: String?, into changes: inout [FileChange]) {
        let letters = Array(xy)
        guard letters.count == 2 else { return }
        let indexStatus = letters[0]
        let worktreeStatus = letters[1]
        if indexStatus != "." {
            changes.append(FileChange(path: path, originalPath: originalPath, area: .staged, statusLetter: String(indexStatus)))
        }
        if worktreeStatus != "." {
            changes.append(FileChange(path: path, originalPath: originalPath, area: .unstaged, statusLetter: String(worktreeStatus)))
        }
    }
}
