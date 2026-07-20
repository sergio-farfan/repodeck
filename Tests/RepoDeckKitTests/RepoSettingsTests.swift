import Foundation
import Testing
@testable import RepoDeckKit

private let jsonDecoder = JSONDecoder()
private let jsonEncoder = JSONEncoder()

@Test("1. Round-trip: fully non-default RepoSettings encodes and decodes equal")
func roundTripFullyNonDefault() throws {
    let settings = RepoSettings(
        isPinned: true,
        autoRebaseOnRejectedPush: true,
        autoFetchInterval: .fifteenMinutes,
        group: "Work"
    )
    let data = try jsonEncoder.encode(settings)
    let decoded = try jsonDecoder.decode(RepoSettings.self, from: data)
    #expect(decoded == settings)
}

@Test("2. Empty-object decode yields all defaults and isDefault == true")
func emptyObjectDecodesToDefaults() throws {
    let data = Data("{}".utf8)
    let decoded = try jsonDecoder.decode(RepoSettings.self, from: data)
    #expect(decoded == RepoSettings())
    #expect(decoded.isDefault)
}

@Test("3. Partial decode: only isPinned set, everything else default")
func partialDecodeOnlyIsPinned() throws {
    let data = Data(#"{"isPinned": true}"#.utf8)
    let decoded = try jsonDecoder.decode(RepoSettings.self, from: data)
    #expect(decoded.isPinned == true)
    #expect(decoded.autoRebaseOnRejectedPush == false)
    #expect(decoded.autoFetchInterval == .off)
    #expect(decoded.group == nil)
}

@Test("4. Unknown autoFetchInterval raw value falls back to .off")
func unknownIntervalRawValueFallsBackToOff() throws {
    let data = Data(#"{"autoFetchInterval": "everyTwoMinutes"}"#.utf8)
    let decoded = try jsonDecoder.decode(RepoSettings.self, from: data)
    #expect(decoded.autoFetchInterval == .off)
}

@Test("5. Unknown extra key is ignored, decode succeeds")
func unknownExtraKeyIsIgnored() throws {
    let data = Data(#"{"isPinned": true, "futureField": 42}"#.utf8)
    let decoded = try jsonDecoder.decode(RepoSettings.self, from: data)
    #expect(decoded.isPinned == true)
}

@Test("6a. isDefault is false when isPinned differs from default")
func isDefaultFalseForIsPinned() {
    #expect(RepoSettings(isPinned: true).isDefault == false)
}

@Test("6b. isDefault is false when autoRebaseOnRejectedPush differs from default")
func isDefaultFalseForAutoRebase() {
    #expect(RepoSettings(autoRebaseOnRejectedPush: true).isDefault == false)
}

@Test("6c. isDefault is false when autoFetchInterval differs from default")
func isDefaultFalseForAutoFetchInterval() {
    #expect(RepoSettings(autoFetchInterval: .oneHour).isDefault == false)
}

@Test("6d. isDefault is false when group differs from default")
func isDefaultFalseForGroup() {
    #expect(RepoSettings(group: "Work").isDefault == false)
}

@Test("6e. isDefault is false when isHidden differs from default")
func isDefaultFalseForIsHidden() {
    #expect(RepoSettings(isHidden: true).isDefault == false)
}

@Test("6f. isDefault is true for the default instance")
func isDefaultTrueForDefaultInstance() {
    #expect(RepoSettings().isDefault)
}

@Test("10. Round-trip: isHidden true survives encode and decode")
func roundTripIsHidden() throws {
    let settings = RepoSettings(isHidden: true)
    let data = try jsonEncoder.encode(settings)
    let decoded = try jsonDecoder.decode(RepoSettings.self, from: data)
    #expect(decoded == settings)
    #expect(decoded.isHidden == true)
}

@Test("11. Legacy decode: JSON without isHidden yields isHidden == false")
func legacyDecodeWithoutIsHidden() throws {
    let data = Data(#"{"isPinned": true}"#.utf8)
    let decoded = try jsonDecoder.decode(RepoSettings.self, from: data)
    #expect(decoded.isHidden == false)
}

@Test("7. seconds maps each interval to its expected TimeInterval")
func secondsMapsEachInterval() {
    #expect(AutoFetchInterval.off.seconds == nil)
    #expect(AutoFetchInterval.fiveMinutes.seconds == 300)
    #expect(AutoFetchInterval.fifteenMinutes.seconds == 900)
    #expect(AutoFetchInterval.thirtyMinutes.seconds == 1800)
    #expect(AutoFetchInterval.oneHour.seconds == 3600)
}

@Test("8a. Migration: pinned-only path yields an entry with only isPinned set")
func migrationPinnedOnlyPath() {
    let result = RepoSettingsMigration.migrate(legacyPinned: ["/repo/a"], legacyAutoRebase: [])
    #expect(result.count == 1)
    #expect(result["/repo/a"] == RepoSettings(isPinned: true))
}

@Test("8b. Migration: rebase-only path yields an entry with only autoRebaseOnRejectedPush set")
func migrationRebaseOnlyPath() {
    let result = RepoSettingsMigration.migrate(legacyPinned: [], legacyAutoRebase: ["/repo/b"])
    #expect(result.count == 1)
    #expect(result["/repo/b"] == RepoSettings(autoRebaseOnRejectedPush: true))
}

@Test("8c. Migration: path in both arrays yields one entry with both flags set")
func migrationPathInBothArrays() {
    let result = RepoSettingsMigration.migrate(legacyPinned: ["/repo/c"], legacyAutoRebase: ["/repo/c"])
    #expect(result.count == 1)
    #expect(result["/repo/c"] == RepoSettings(isPinned: true, autoRebaseOnRejectedPush: true))
}

@Test("8d. Migration: empty arrays yield an empty dictionary")
func migrationEmptyArraysYieldEmptyDictionary() {
    let result = RepoSettingsMigration.migrate(legacyPinned: [], legacyAutoRebase: [])
    #expect(result.isEmpty)
}

@Test("8e. Migration: no entry in the result has isDefault == true")
func migrationNeverProducesDefaultEntries() {
    let result = RepoSettingsMigration.migrate(
        legacyPinned: ["/repo/a", "/repo/c"],
        legacyAutoRebase: ["/repo/b", "/repo/c"]
    )
    #expect(!result.values.contains { $0.isDefault })
}

@Test("9. Dictionary round-trip: [String: RepoSettings] encodes and decodes intact")
func dictionaryRoundTrip() throws {
    let settings: [String: RepoSettings] = [
        "/repo/a": RepoSettings(isPinned: true),
        "/repo/b": RepoSettings(autoRebaseOnRejectedPush: true, autoFetchInterval: .thirtyMinutes, group: "Personal"),
    ]
    let data = try jsonEncoder.encode(settings)
    let decoded = try jsonDecoder.decode([String: RepoSettings].self, from: data)
    #expect(decoded == settings)
}
