import Foundation

/// Effective `git config` identity for one repo (local overriding global).
/// Either field can be nil — git happily has one without the other.
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
}
