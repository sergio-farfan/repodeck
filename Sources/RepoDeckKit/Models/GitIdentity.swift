import Foundation

public enum GitIdentityScope: String, CaseIterable, Sendable {
    case repository
    case globalDefault
}

/// Name and email read from Git configuration or resolved by Git for an author.
/// Missing configuration fields are nil; a Git-resolved author can have an
/// explicitly empty email if Git accepts that identity.
public struct GitIdentity: Sendable, Equatable {
    public let name: String?
    public let email: String?

    public init(name: String?, email: String?) {
        self.name = name
        self.email = email
    }

    /// Up-to-two uppercase initials from `name` (first + last word), falling
    /// back to the first letter of `email`, else nil.
    public var initials: String? {
        if let name {
            let words = name.split(whereSeparator: \.isWhitespace)
            if let first = words.first?.first {
                if words.count > 1, let last = words.last?.first {
                    return (String(first) + String(last)).uppercased()
                }
                return String(first).uppercased()
            }
        }
        if let first = email?.first {
            return String(first).uppercased()
        }
        return nil
    }

    /// True when at least one of the two fields is set — "half-configured"
    /// still counts as configured; only a fully blank identity is not.
    public var isConfigured: Bool { name != nil || email != nil }

    /// Whether both fields have nonblank text, for configuration-form checks.
    /// Git itself determines whether a resolved author is valid for a commit.
    public var isComplete: Bool {
        guard let name, let email else { return false }
        return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
