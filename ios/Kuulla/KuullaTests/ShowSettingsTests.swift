import XCTest
@testable import Kuulla

final class ShowSettingsTests: XCTestCase {
    private let base = ShowSettings(
        id: "show:u1:s1", userId: "u1", showId: "s1", unlistenedEpisodeCount: .ten,
        version: 1, autoArchiveRule: .after7Days, autoSkipIntroSeconds: 10, autoSkipOutroSeconds: 20,
        playbackSpeed: 1.5, autoDownloadNewEpisodes: true, autoDeleteRule: .afterDays, autoDeleteAfterDays: 14,
        smartSpeed: true, autoAddNewEpisodesToUpNext: true, playNextBehavior: .topOfList)

    func testWithChangingOneFieldPreservesEveryOtherField() {
        let updated = base.with(playbackSpeed: 2.0)

        XCTAssertEqual(updated.playbackSpeed, 2.0)
        XCTAssertEqual(updated.unlistenedEpisodeCount, base.unlistenedEpisodeCount)
        XCTAssertEqual(updated.autoArchiveRule, base.autoArchiveRule)
        XCTAssertEqual(updated.autoSkipIntroSeconds, base.autoSkipIntroSeconds)
        XCTAssertEqual(updated.autoSkipOutroSeconds, base.autoSkipOutroSeconds)
        // The bug this regresses against: an earlier hand-written reconstruction in
        // ShowSettingsSheet.updatePlaybackSpeedOverride omitted autoDownloadNewEpisodes
        // entirely, which would have silently cleared this override.
        XCTAssertEqual(updated.autoDownloadNewEpisodes, base.autoDownloadNewEpisodes)
        XCTAssertEqual(updated.smartSpeed, base.smartSpeed)
        XCTAssertEqual(updated.autoAddNewEpisodesToUpNext, base.autoAddNewEpisodesToUpNext)
        XCTAssertEqual(updated.autoDeleteRule, base.autoDeleteRule)
        XCTAssertEqual(updated.autoDeleteAfterDays, base.autoDeleteAfterDays)
        XCTAssertEqual(updated.playNextBehavior, base.playNextBehavior)
    }

    func testWithExplicitNilClearsThePlayNextBehaviorOverride() {
        let updated = base.with(playNextBehavior: PlayNextBehavior?.none)
        XCTAssertNil(updated.playNextBehavior)
    }

    func testWithSetsThePlayNextBehaviorOverride() {
        let updated = base.with(playNextBehavior: PlayNextBehavior?.some(.stop))
        XCTAssertEqual(updated.playNextBehavior, .stop)
    }

    func testWithChangingAutoDeleteRuleAndAfterDaysTogether() {
        let updated = base.with(autoDeleteRule: AutoDeleteRule?.some(.never), autoDeleteAfterDays: Int?.none)
        XCTAssertEqual(updated.autoDeleteRule, .never)
        XCTAssertNil(updated.autoDeleteAfterDays)
        // Other fields untouched.
        XCTAssertEqual(updated.autoDownloadNewEpisodes, base.autoDownloadNewEpisodes)
    }

    func testWithExplicitNilClearsTheAutoDeleteRuleOverride() {
        let updated = base.with(autoDeleteRule: AutoDeleteRule?.none)
        XCTAssertNil(updated.autoDeleteRule)
        // afterDays left untouched because it wasn't passed.
        XCTAssertEqual(updated.autoDeleteAfterDays, base.autoDeleteAfterDays)
    }

    func testWithExplicitNilClearsTheAutoAddUpNextOverride() {
        let updated = base.with(autoAddNewEpisodesToUpNext: Bool?.none)
        XCTAssertNil(updated.autoAddNewEpisodesToUpNext)
    }

    func testWithNoArgumentsReturnsAnEquivalentCopy() {
        XCTAssertEqual(base.with(), base)
    }

    // The double-optional parameter is what makes "clear this override" distinguishable from
    // "don't touch this field" — verify both directions.
    func testWithExplicitNilClearsTheOverride() {
        let updated = base.with(autoDownloadNewEpisodes: Bool?.none)
        XCTAssertNil(updated.autoDownloadNewEpisodes)
    }

    func testOmittingArgumentLeavesOverrideUntouched() {
        // Passes a genuinely different, non-nil value for a different field — unlike
        // `with(playbackSpeed: nil)`, which is ambiguous-looking (nil-for-omission vs.
        // nil-for-clear) even though it happens to mean "omitted" here, this leaves no doubt
        // that autoDownloadNewEpisodes's unchanged value comes from being untouched, not from
        // some nil-handling coincidence.
        let updated = base.with(autoSkipIntroSeconds: 99)
        XCTAssertEqual(updated.autoDownloadNewEpisodes, base.autoDownloadNewEpisodes)
    }
}
