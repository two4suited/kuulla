import XCTest
@testable import Kuulla

final class UserSettingsTests: XCTestCase {
    private let base = UserSettings(
        userId: "u1", unlistenedEpisodeCount: .five, version: 1, autoArchiveRule: .after7Days,
        autoSkipIntroSeconds: 10, autoSkipOutroSeconds: 20, playbackSpeed: 1.5,
        autoDeleteRule: .afterPlayed, autoDeleteAfterDays: 14, autoDownloadNewEpisodes: true)

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
}
