import XCTest
@testable import Kuulla

final class ShowSettingsTests: XCTestCase {
    private let base = ShowSettings(
        id: "show:u1:s1", userId: "u1", showId: "s1", unlistenedEpisodeCount: .ten,
        version: 1, autoArchiveRule: .after7Days, autoSkipIntroSeconds: 10, autoSkipOutroSeconds: 20,
        playbackSpeed: 1.5, autoDownloadNewEpisodes: true, smartSpeed: true)

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
