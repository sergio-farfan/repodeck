import Foundation

public struct Commit: Identifiable, Hashable, Sendable {
    public let hash: String
    public let shortHash: String
    public let subject: String
    public let author: String
    public let date: Date                // parsed from ISO8601 (%aI)
    public let refs: [String]            // %D split on ", "; [] when undecorated

    public var id: String { hash }

    public init(hash: String, shortHash: String, subject: String, author: String, date: Date, refs: [String]) {
        self.hash = hash
        self.shortHash = shortHash
        self.subject = subject
        self.author = author
        self.date = date
        self.refs = refs
    }
}
