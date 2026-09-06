import XCTest
@testable import Kuulla

final class UserSettingsTests: XCTestCase {
    private let base = UserSettings(
        userId: "u1", unlistenedEpisodeCount: .five, version: 1, autoArchiveRule: .after7Days,
        autoSkipIntroSeconds: 10, autoSkipOutroSeconds: 20, playbackSpeed: 1.5,
        autoDeleteRule: .afterPlayed, autoDeleteAfterDays: 14, autoDownloadNewEpisodes: true, smartSpeed: true,
        sleepTimerDefaultDurationMinutes: 15)

    func testWithChangingOneFieldPreservesEveryOtherField() {
        let updated = base.with(playbackSpeed: 2.0)

        XCTAssertEqual(updated.playbackSpeed, 2.0)
        XCTAssertEqual(updated.userId, base.userId)
        XCTAssertEqual(updated.unlistenedEpisodeCount, base.unlistenedEpisodeCount)
        XCTAssertEqual(updated.version, base.version)
        XCTAssertEqual(updated.autoArchiveRule, base.autoArchiveRule)
        XCTAssertEqual(updated.autoSkipIntroSeconds, base.autoSkipIntroSeconds)
        XCTAssertEqual(updated.autoSkipOutroSeconds, base.autoSkipOutroSeconds)
        XCTAssertEqual(updated.autoDeleteRule, base.autoDeleteRule)
        XCTAssertEqual(updated.autoDeleteAfterDays, base.autoDeleteAfterDays)
        XCTAssertEqual(updated.autoDownloadNewEpisodes, base.autoDownloadNewEpisodes)
        // Regresses against the same bug class ShowSettingsTests guards against: a hand-written
        // `with()` that omits a field silently resets it to that field's default instead of
        // preserving it.
        XCTAssertEqual(updated.smartSpeed, base.smartSpeed)
        XCTAssertEqual(updated.sleepTimerDefaultDurationMinutes, base.sleepTimerDefaultDurationMinutes)
        XCTAssertEqual(updated.subscriptionSortOrder, base.subscriptionSortOrder)
        XCTAssertEqual(updated.subscriptionManualOrder, base.subscriptionManualOrder)
        XCTAssertEqual(updated.hideCaughtUpShows, base.hideCaughtUpShows)
    }

    func testWithSetsHideCaughtUpShows() {
        let updated = base.with(hideCaughtUpShows: true)

        XCTAssertTrue(updated.hideCaughtUpShows)
    }

    func testDecodingResponseMissingHideCaughtUpShowsDefaultsToFalse() throws {
        let json = """
            {"userId":"u1","unlistenedEpisodeCount":5,"version":1,"autoArchiveRule":0}
            """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(UserSettings.self, from: json)

        XCTAssertFalse(decoded.hideCaughtUpShows)
    }

    func testDecodingHideCaughtUpShowsFromWireBool() throws {
        let json = """
            {"userId":"u1","unlistenedEpisodeCount":5,"version":1,"autoArchiveRule":0,"hideCaughtUpShows":true}
            """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(UserSettings.self, from: json)

        XCTAssertTrue(decoded.hideCaughtUpShows)
    }

    func testWithSetsSubscriptionSortOrder() {
        let updated = base.with(subscriptionSortOrder: .recentlyAdded)

        XCTAssertEqual(updated.subscriptionSortOrder, .recentlyAdded)
    }

    func testWithSetsSubscriptionManualOrder() {
        let updated = base.with(subscriptionManualOrder: ["show-b", "show-a"])

        XCTAssertEqual(updated.subscriptionManualOrder, ["show-b", "show-a"])
    }

    func testDecodingResponseMissingSubscriptionManualOrderDefaultsToEmpty() throws {
        let json = """
            {"userId":"u1","unlistenedEpisodeCount":5,"version":1,"autoArchiveRule":0}
            """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(UserSettings.self, from: json)

        XCTAssertEqual(decoded.subscriptionManualOrder, [])
    }

    func testDecodingSubscriptionManualOrderFromWireArray() throws {
        let json = """
            {"userId":"u1","unlistenedEpisodeCount":5,"version":1,"autoArchiveRule":0,"subscriptionManualOrder":["x","y","z"]}
            """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(UserSettings.self, from: json)

        XCTAssertEqual(decoded.subscriptionManualOrder, ["x", "y", "z"])
    }

    func testDecodingResponseMissingSubscriptionSortOrderDefaultsToTitle() throws {
        let json = """
            {"userId":"u1","unlistenedEpisodeCount":5,"version":1,"autoArchiveRule":0}
            """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(UserSettings.self, from: json)

        XCTAssertEqual(decoded.subscriptionSortOrder, .title)
    }

    func testDecodingSubscriptionSortOrderFromWireInteger() throws {
        let json = """
            {"userId":"u1","unlistenedEpisodeCount":5,"version":1,"autoArchiveRule":0,"subscriptionSortOrder":2}
            """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(UserSettings.self, from: json)

        XCTAssertEqual(decoded.subscriptionSortOrder, .recentlyAdded)
    }

    func testWithNoArgumentsReturnsAnEquivalentCopy() {
        XCTAssertEqual(base.with(), base)
    }

    func testWithFalseBooleanIsNotMistakenForNoChange() {
        // A naive `?? self.x` bug could treat an explicit `false` as "not provided" if the
        // parameter type were `Bool` instead of `Bool?` — verify the real (optional) parameter
        // correctly applies false rather than falling back to base's `true`.
        let updated = base.with(autoDownloadNewEpisodes: false)
        XCTAssertFalse(updated.autoDownloadNewEpisodes)
    }

    func testWithSetsSleepTimerDefaultDurationMinutes() {
        let updated = base.with(sleepTimerDefaultDurationMinutes: 45)

        XCTAssertEqual(updated.sleepTimerDefaultDurationMinutes, 45)
    }

    func testDecodingLegacyResponseMissingSleepTimerDefaultDurationMinutesDefaultsToNil() throws {
        let json = """
            {"userId":"u1","unlistenedEpisodeCount":5,"version":1,"autoArchiveRule":0}
            """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(UserSettings.self, from: json)

        XCTAssertNil(decoded.sleepTimerDefaultDurationMinutes)
    }
}
