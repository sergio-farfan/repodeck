import Foundation

/// Background auto-fetch cadence for a repo.
public enum AutoFetchInterval: String, Codable, CaseIterable, Sendable {
    case off, fiveMinutes, fifteenMinutes, thirtyMinutes, oneHour

    /// `nil` for `.off`; otherwise the interval in seconds.
    public var seconds: TimeInterval? {
        switch self {
        case .off: return nil
        case .fiveMinutes: return 300
        case .fifteenMinutes: return 900
        case .thirtyMinutes: return 1800
        case .oneHour: return 3600
        }
    }

    /// Human label for pickers.
    public var label: String {
        switch self {
        case .off: return "Off"
        case .fiveMinutes: return "Every 5 minutes"
        case .fifteenMinutes: return "Every 15 minutes"
        case .thirtyMinutes: return "Every 30 minutes"
        case .oneHour: return "Every hour"
        }
    }
}

/// Consolidated per-repo settings. The app layer persists these as a
/// path-keyed `[String: RepoSettings]` dictionary (a later task's job);
/// this type carries no UserDefaults/I/O concerns of its own.
///
/// Decoding is forward/backward tolerant: any missing field falls back to
/// its default (so a future field added here won't invalidate previously
/// persisted data), and an unrecognized `autoFetchInterval` raw value falls
/// back to `.off` rather than throwing (so older builds can read data
/// written by a newer build that introduced new interval cases).
public struct RepoSettings: Codable, Sendable, Equatable {
    public var isPinned: Bool
    public var autoRebaseOnRejectedPush: Bool
    public var autoFetchInterval: AutoFetchInterval
    public var group: String?
    /// Whether the repo is hidden from the dashboard. A hidden repo is
    /// filtered out on every rescan (never deleted from disk) until unhidden.
    public var isHidden: Bool

    public init(
        isPinned: Bool = false,
        autoRebaseOnRejectedPush: Bool = false,
        autoFetchInterval: AutoFetchInterval = .off,
        group: String? = nil,
        isHidden: Bool = false
    ) {
        self.isPinned = isPinned
        self.autoRebaseOnRejectedPush = autoRebaseOnRejectedPush
        self.autoFetchInterval = autoFetchInterval
        self.group = group
        self.isHidden = isHidden
    }

    /// True when every field equals its default — such entries are pruned
    /// from the persisted dictionary rather than stored.
    public var isDefault: Bool {
        self == RepoSettings()
    }

    private enum CodingKeys: String, CodingKey {
        case isPinned, autoRebaseOnRejectedPush, autoFetchInterval, group, isHidden
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        autoRebaseOnRejectedPush = try container.decodeIfPresent(Bool.self, forKey: .autoRebaseOnRejectedPush) ?? false
        let rawInterval = try container.decodeIfPresent(String.self, forKey: .autoFetchInterval)
        autoFetchInterval = rawInterval.flatMap(AutoFetchInterval.init(rawValue:)) ?? .off
        group = try container.decodeIfPresent(String.self, forKey: .group)
        isHidden = try container.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isPinned, forKey: .isPinned)
        try container.encode(autoRebaseOnRejectedPush, forKey: .autoRebaseOnRejectedPush)
        try container.encode(autoFetchInterval, forKey: .autoFetchInterval)
        try container.encodeIfPresent(group, forKey: .group)
        try container.encode(isHidden, forKey: .isHidden)
    }
}

/// Migrates the two legacy path-keyed string arrays (`pinnedRepoIDs`,
/// `autoRebaseRepoIDs`) into the consolidated per-repo settings dictionary.
public enum RepoSettingsMigration {
    /// Builds the consolidated per-repo settings dictionary from the two
    /// legacy path-keyed string arrays. A path present in both arrays
    /// yields one entry with both flags set. Never produces all-default
    /// entries.
    public static func migrate(legacyPinned: [String], legacyAutoRebase: [String]) -> [String: RepoSettings] {
        var result: [String: RepoSettings] = [:]

        for path in legacyPinned {
            result[path, default: RepoSettings()].isPinned = true
        }
        for path in legacyAutoRebase {
            result[path, default: RepoSettings()].autoRebaseOnRejectedPush = true
        }

        return result
    }
}
