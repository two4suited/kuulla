import XCTest
@testable import Kuulla

final class CrossDeviceResumeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func prompt(
        syncedPositionSeconds: Int = 600,
        syncedUpdatedAt: Date? = nil,
        syncedDeviceId: String? = "other-device",
        completed: Bool = false,
        currentDeviceId: String = "this-device",
        lastLocalPositionSeconds: Int = 0,
        lastLocalPlaybackAt: Date = .distantPast
    ) -> CrossDeviceResume.Prompt? {
        CrossDeviceResume.prompt(
            syncedPositionSeconds: syncedPositionSeconds,
            syncedUpdatedAt: syncedUpdatedAt ?? now,
            syncedDeviceId: syncedDeviceId,
            completed: completed,
            currentDeviceId: currentDeviceId,
            lastLocalPositionSeconds: lastLocalPositionSeconds,
            lastLocalPlaybackAt: lastLocalPlaybackAt)
    }

    func testPromptsWhenAnotherDeviceMovedPastThisDevice() {
        let result = prompt(syncedPositionSeconds: 600, lastLocalPositionSeconds: 120,
                            lastLocalPlaybackAt: now.addingTimeInterval(-3600))
        XCTAssertEqual(result, CrossDeviceResume.Prompt(otherDevicePositionSeconds: 600, localPositionSeconds: 120))
    }

    func testPromptsForEpisodeNeverPlayedOnThisDevice() {
        let result = prompt(syncedPositionSeconds: 300)
        XCTAssertEqual(result, CrossDeviceResume.Prompt(otherDevicePositionSeconds: 300, localPositionSeconds: 0))
    }

    func testNoPromptWhenSyncedDeviceIsThisDevice() {
        XCTAssertNil(prompt(syncedDeviceId: "this-device"))
    }

    func testNoPromptWhenDeviceIdUnknown() {
        // Position never round-tripped through sync — can't attribute it to another device.
        XCTAssertNil(prompt(syncedDeviceId: nil))
    }

    func testNoPromptWhenEpisodeCompleted() {
        XCTAssertNil(prompt(completed: true))
    }

    func testNoPromptWhenThisDevicePlayedMoreRecently() {
        XCTAssertNil(prompt(syncedUpdatedAt: now.addingTimeInterval(-10), lastLocalPlaybackAt: now))
    }

    func testNoPromptWhenPositionsAreWithinThreshold() {
        let result = prompt(syncedPositionSeconds: 610, lastLocalPositionSeconds: 600,
                            lastLocalPlaybackAt: now.addingTimeInterval(-3600))
        XCTAssertNil(result)
    }

    func testPromptsWhenOtherDeviceIsBehindThisDeviceByMoreThanThreshold() {
        // Handoff isn't only "further along" — another device rewinding well past this one still
        // warrants the offer.
        let result = prompt(syncedPositionSeconds: 60, lastLocalPositionSeconds: 600,
                            lastLocalPlaybackAt: now.addingTimeInterval(-3600))
        XCTAssertEqual(result, CrossDeviceResume.Prompt(otherDevicePositionSeconds: 60, localPositionSeconds: 600))
    }
}

final class CrossDeviceHandoffTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func banner(
        syncedPositionSeconds: Int = 900,
        syncedUpdatedAt: Date? = nil,
        syncedDeviceId: String? = "other-device",
        completed: Bool = false,
        currentDeviceId: String = "this-device",
        currentPlaybackPositionSeconds: Int = 300,
        lastSurfacedUpdatedAt: Date? = nil
    ) -> CrossDeviceHandoff.Banner? {
        CrossDeviceHandoff.banner(
            syncedPositionSeconds: syncedPositionSeconds,
            syncedUpdatedAt: syncedUpdatedAt ?? now,
            syncedDeviceId: syncedDeviceId,
            completed: completed,
            currentDeviceId: currentDeviceId,
            currentPlaybackPositionSeconds: currentPlaybackPositionSeconds,
            lastSurfacedUpdatedAt: lastSurfacedUpdatedAt)
    }

    func testBannerWhenAnotherDeviceJumpedAheadDuringPlayback() {
        XCTAssertEqual(banner(), CrossDeviceHandoff.Banner(targetPositionSeconds: 900, sourceUpdatedAt: now))
    }

    func testNoBannerForOwnDevice() {
        XCTAssertNil(banner(syncedDeviceId: "this-device"))
    }

    func testNoBannerWhenDeviceIdUnknown() {
        XCTAssertNil(banner(syncedDeviceId: nil))
    }

    func testNoBannerWhenCompleted() {
        XCTAssertNil(banner(completed: true))
    }

    func testNoBannerWhenWithinThreshold() {
        XCTAssertNil(banner(syncedPositionSeconds: 310, currentPlaybackPositionSeconds: 300))
    }

    func testNoBannerWhenAlreadySurfacedForThisRemoteWrite() {
        XCTAssertNil(banner(syncedUpdatedAt: now, lastSurfacedUpdatedAt: now))
    }

    func testBannerAgainForANewerRemoteWrite() {
        let result = banner(syncedUpdatedAt: now.addingTimeInterval(30), lastSurfacedUpdatedAt: now)
        XCTAssertEqual(result?.targetPositionSeconds, 900)
    }
}
