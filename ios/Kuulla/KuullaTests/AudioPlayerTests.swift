import MediaPlayer
import XCTest
@testable import Kuulla

final class AudioPlayerTests: XCTestCase {
    // Now Playing tests read/write the process-wide MPNowPlayingInfoCenter singleton — without
    // this, a later test could observe a value left behind by an earlier one, making the suite
    // order-dependent.
    override func tearDown() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        super.tearDown()
    }

    // MARK: - Now Playing info (#116)

    func testPlayWithMetadataPublishesNowPlayingInfo() {
        let player = AudioPlayer()
        let url = URL(string: "https://example.com/audio.mp3")!

        player.play(
            url: url, metadata: NowPlayingMetadata(title: "Episode Title", showTitle: "Show Title", artworkURL: nil))

        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo
        XCTAssertEqual(info?[MPMediaItemPropertyTitle] as? String, "Episode Title")
        XCTAssertEqual(info?[MPMediaItemPropertyArtist] as? String, "Show Title")
        XCTAssertEqual(info?[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1.0)
    }

    func testPauseSetsNowPlayingPlaybackRateToZero() {
        let player = AudioPlayer()
        player.play(
            url: URL(string: "https://example.com/audio.mp3")!,
            metadata: NowPlayingMetadata(title: "Episode Title", showTitle: nil, artworkURL: nil))

        player.pause()

        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo
        XCTAssertEqual(info?[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0)
    }

    func testPlayWithoutMetadataClearsNowPlayingInfo() {
        let player = AudioPlayer()

        player.play(url: URL(string: "https://example.com/audio.mp3")!)

        XCTAssertNil(MPNowPlayingInfoCenter.default().nowPlayingInfo)
    }

    func testPlaySetsPlayingStateAndCurrentURL() {
        let player = AudioPlayer()
        let url = URL(string: "https://example.com/audio.mp3")!

        player.play(url: url)

        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(player.currentURL, url)
    }

    func testPauseClearsPlayingState() {
        let player = AudioPlayer()
        player.play(url: URL(string: "https://example.com/audio.mp3")!)

        player.pause()

        XCTAssertFalse(player.isPlaying)
    }

    func testResumeSetsPlayingStateBackToTrue() {
        let player = AudioPlayer()
        player.play(url: URL(string: "https://example.com/audio.mp3")!)
        player.pause()

        player.resume()

        XCTAssertTrue(player.isPlaying)
    }

    func testPlayingANewURLReplacesCurrentURL() {
        let player = AudioPlayer()
        let firstURL = URL(string: "https://example.com/first.mp3")!
        let secondURL = URL(string: "https://example.com/second.mp3")!

        player.play(url: firstURL)
        player.play(url: secondURL)

        XCTAssertEqual(player.currentURL, secondURL)
        XCTAssertTrue(player.isPlaying)
    }

    func testPlayWithStartPositionSeedsCurrentTime() {
        let player = AudioPlayer()

        player.play(url: URL(string: "https://example.com/audio.mp3")!, startPosition: 120)

        XCTAssertEqual(player.currentTime, 120)
    }

    func testPlayWithoutStartPositionDefaultsCurrentTimeToZero() {
        let player = AudioPlayer()

        player.play(url: URL(string: "https://example.com/audio.mp3")!)

        XCTAssertEqual(player.currentTime, 0)
    }

    func testPlayingANewURLResetsCurrentTimeAndDuration() {
        let player = AudioPlayer()

        player.play(url: URL(string: "https://example.com/first.mp3")!, startPosition: 120)
        player.play(url: URL(string: "https://example.com/second.mp3")!)

        XCTAssertEqual(player.currentTime, 0)
        XCTAssertEqual(player.duration, 0)
    }

    func testPlayWithAutoSkipIntroSeeksCurrentTimeToIntroSecondsOnFreshStart() {
        let player = AudioPlayer()

        player.play(url: URL(string: "https://example.com/audio.mp3")!, autoSkipIntroSeconds: 15)

        XCTAssertEqual(player.currentTime, 15)
    }

    func testPlayWithAutoSkipIntroIsIgnoredWhenResumingFromASavedPosition() {
        let player = AudioPlayer()

        player.play(
            url: URL(string: "https://example.com/audio.mp3")!, startPosition: 300, autoSkipIntroSeconds: 15)

        XCTAssertEqual(player.currentTime, 300)
    }

    func testShouldTriggerOutroSkipFiresOnceCurrentTimeReachesTheOutroThreshold() {
        XCTAssertFalse(AudioPlayer.shouldTriggerOutroSkip(currentTime: 560, duration: 600, autoSkipOutroSeconds: 30))
        XCTAssertTrue(AudioPlayer.shouldTriggerOutroSkip(currentTime: 570, duration: 600, autoSkipOutroSeconds: 30))
        XCTAssertTrue(AudioPlayer.shouldTriggerOutroSkip(currentTime: 590, duration: 600, autoSkipOutroSeconds: 30))
    }

    func testShouldTriggerOutroSkipIsFalseWhenOutroSkipIsOff() {
        XCTAssertFalse(AudioPlayer.shouldTriggerOutroSkip(currentTime: 590, duration: 600, autoSkipOutroSeconds: 0))
    }

    func testShouldTriggerOutroSkipIsFalseWhenOutroSkipIsLongerThanTheEpisode() {
        // A misconfigured outro-skip longer than the episode itself should never fire — it's
        // treated as a no-op, not "skip the whole episode instantly".
        XCTAssertFalse(AudioPlayer.shouldTriggerOutroSkip(currentTime: 590, duration: 600, autoSkipOutroSeconds: 700))
    }

    func testShouldTriggerOutroSkipIsFalseBeforeDurationIsKnown() {
        XCTAssertFalse(AudioPlayer.shouldTriggerOutroSkip(currentTime: 0, duration: 0, autoSkipOutroSeconds: 30))
    }

    func testPlayWithoutPlaybackSpeedDefaultsToNormalSpeed() {
        let player = AudioPlayer()

        player.play(url: URL(string: "https://example.com/audio.mp3")!)

        XCTAssertEqual(player.playbackSpeed, 1.0)
        XCTAssertEqual(player.currentPlayerRate, 1.0)
    }

    func testPlayWithPlaybackSpeedSeedsPlaybackSpeed() {
        let player = AudioPlayer()

        player.play(url: URL(string: "https://example.com/audio.mp3")!, playbackSpeed: 1.5)

        XCTAssertEqual(player.playbackSpeed, 1.5)
        XCTAssertEqual(player.currentPlayerRate, 1.5)
    }

    // Guards against the pitch-correction wiring silently regressing — a plain rate change
    // without .timeDomain would distort pitch (the "chipmunk effect") instead of staying
    // spoken-word-optimized.
    func testPlaySetsTimeDomainPitchAlgorithm() {
        let player = AudioPlayer()

        player.play(url: URL(string: "https://example.com/audio.mp3")!, playbackSpeed: 1.5)

        XCTAssertEqual(player.currentPitchAlgorithm, .timeDomain)
    }

    func testSetPlaybackSpeedUpdatesSpeedWhilePlaying() {
        let player = AudioPlayer()
        player.play(url: URL(string: "https://example.com/audio.mp3")!)

        player.setPlaybackSpeed(2.0)

        XCTAssertEqual(player.playbackSpeed, 2.0)
        XCTAssertEqual(player.currentPlayerRate, 2.0)
        XCTAssertTrue(player.isPlaying)
    }

    func testSetPlaybackSpeedDoesNotResumePlaybackWhilePaused() {
        let player = AudioPlayer()
        player.play(url: URL(string: "https://example.com/audio.mp3")!)
        player.pause()

        player.setPlaybackSpeed(2.0)

        XCTAssertEqual(player.playbackSpeed, 2.0)
        // The underlying player must stay at rate 0 (paused) even though the desired speed
        // changed — asserting only isPlaying wouldn't catch a regression where the rate itself
        // gets nudged off zero without flipping isPlaying back to true.
        XCTAssertEqual(player.currentPlayerRate, 0)
        XCTAssertFalse(player.isPlaying)
    }

    func testResumePreservesPlaybackSpeed() {
        let player = AudioPlayer()
        player.play(url: URL(string: "https://example.com/audio.mp3")!, playbackSpeed: 1.75)
        player.pause()

        player.resume()

        XCTAssertEqual(player.playbackSpeed, 1.75)
        XCTAssertEqual(player.currentPlayerRate, 1.75)
        XCTAssertTrue(player.isPlaying)
    }

    // A saved-position seek never completes against a fake URL (no real asset loads), so the
    // window right after this play() call is deterministically "seek still pending" — exactly
    // the window setPlaybackSpeed() must not apply a rate in, since play() hasn't actually
    // started audio yet (rate 0) despite isPlaying already reading true optimistically.
    func testSetPlaybackSpeedDoesNotApplyRateWhileSeekIsPending() {
        let player = AudioPlayer()
        player.play(url: URL(string: "https://example.com/audio.mp3")!, startPosition: 120)

        player.setPlaybackSpeed(2.0)

        XCTAssertEqual(player.playbackSpeed, 2.0)
        XCTAssertEqual(player.currentPlayerRate, 0)
        XCTAssertTrue(player.isPlaying)
    }

    func testPauseDuringPendingSeekLeavesPlayerPaused() {
        let player = AudioPlayer()
        player.play(url: URL(string: "https://example.com/audio.mp3")!, startPosition: 120)

        player.pause()

        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.currentPlayerRate, 0)
    }

    // MARK: - Stream over Wi-Fi only (#271)

    private func withWifiOnlyStreaming(_ enabled: Bool, _ body: () async throws -> Void) async rethrows {
        let previous = UserDefaults.standard.object(forKey: LocalSettings.wifiOnlyStreamingKey)
        UserDefaults.standard.set(enabled, forKey: LocalSettings.wifiOnlyStreamingKey)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: LocalSettings.wifiOnlyStreamingKey)
            } else {
                UserDefaults.standard.removeObject(forKey: LocalSettings.wifiOnlyStreamingKey)
            }
        }
        try await body()
    }

    func testPlayRefusesRemoteStreamWhenWifiOnlyStreamingEnabledAndOffWifi() async throws {
        try await withWifiOnlyStreaming(true) {
            let pathObserver = MockPathObserver()
            let player = AudioPlayer(pathObserver: pathObserver)
            await pathObserver.simulate(isOnWifi: false)

            player.play(url: URL(string: "https://example.com/audio.mp3")!)

            XCTAssertFalse(player.isPlaying)
            XCTAssertNil(player.currentURL)
            XCTAssertNotNil(player.streamBlockedMessage)
        }
    }

    func testPlayStartsRemoteStreamWhenWifiOnlyStreamingEnabledAndOnWifi() async throws {
        try await withWifiOnlyStreaming(true) {
            let pathObserver = MockPathObserver()
            let player = AudioPlayer(pathObserver: pathObserver)
            await pathObserver.simulate(isOnWifi: true)

            player.play(url: URL(string: "https://example.com/audio.mp3")!)

            XCTAssertTrue(player.isPlaying)
            XCTAssertNil(player.streamBlockedMessage)
        }
    }

    func testPlayIgnoresWifiOnlyStreamingWhenSettingIsOff() async throws {
        try await withWifiOnlyStreaming(false) {
            let pathObserver = MockPathObserver()
            let player = AudioPlayer(pathObserver: pathObserver)
            await pathObserver.simulate(isOnWifi: false)

            player.play(url: URL(string: "https://example.com/audio.mp3")!)

            XCTAssertTrue(player.isPlaying)
            XCTAssertNil(player.streamBlockedMessage)
        }
    }

    func testPlayNeverGatesALocalFileURLRegardlessOfWifiOnlyStreaming() async throws {
        try await withWifiOnlyStreaming(true) {
            let pathObserver = MockPathObserver()
            let player = AudioPlayer(pathObserver: pathObserver)
            await pathObserver.simulate(isOnWifi: false)

            player.play(url: URL(fileURLWithPath: "/tmp/downloaded-episode.mp3"))

            XCTAssertTrue(player.isPlaying)
            XCTAssertNil(player.streamBlockedMessage)
        }
    }

    func testStreamBlockedURLIsScopedToTheBlockedEpisode() async throws {
        try await withWifiOnlyStreaming(true) {
            let pathObserver = MockPathObserver()
            let player = AudioPlayer(pathObserver: pathObserver)
            await pathObserver.simulate(isOnWifi: false)
            let blockedURL = URL(string: "https://example.com/blocked.mp3")!
            let otherURL = URL(string: "https://example.com/other.mp3")!

            player.play(url: blockedURL)

            XCTAssertEqual(player.streamBlockedURL, blockedURL)
            // A view rendering for a different episode must not mistake this message as its own.
            XCTAssertNotEqual(player.streamBlockedURL, otherURL)
        }
    }

    func testPlayClearsAStaleStreamBlockedMessageOnceBackOnWifi() async throws {
        try await withWifiOnlyStreaming(true) {
            let pathObserver = MockPathObserver()
            let player = AudioPlayer(pathObserver: pathObserver)
            await pathObserver.simulate(isOnWifi: false)
            player.play(url: URL(string: "https://example.com/audio.mp3")!)
            XCTAssertNotNil(player.streamBlockedMessage)

            await pathObserver.simulate(isOnWifi: true)
            player.play(url: URL(string: "https://example.com/audio.mp3")!)

            XCTAssertNil(player.streamBlockedMessage)
            XCTAssertTrue(player.isPlaying)
        }
    }

    // MARK: - Remote command routing (#118)
    //
    // CPNowPlayingTemplate, the lock screen, and Control Center all send taps through the same
    // MPRemoteCommandCenter targets configureRemoteCommandCenter() registers — there's no
    // separate CarPlay playback path, so these handle*Command methods are what CarPlay's
    // transport controls actually invoke. MPRemoteCommandEvent has no public initializer, so a
    // real command can't be simulated end-to-end here — these call the extracted handler methods
    // directly instead, which is the entire body of what each MPRemoteCommandCenter target does.

    func testHandlePlayCommandResumesPlayback() {
        let player = AudioPlayer()
        player.play(url: URL(string: "https://example.com/audio.mp3")!)
        player.pause()

        let status = player.handlePlayCommand()

        XCTAssertEqual(status, .success)
        XCTAssertTrue(player.isPlaying)
    }

    func testHandlePlayCommandWithNoActiveItemReturnsNoActionableNowPlayingItem() {
        let player = AudioPlayer()

        XCTAssertEqual(player.handlePlayCommand(), .noActionableNowPlayingItem)
    }

    func testHandlePauseCommandPausesPlayback() {
        let player = AudioPlayer()
        player.play(url: URL(string: "https://example.com/audio.mp3")!)

        let status = player.handlePauseCommand()

        XCTAssertEqual(status, .success)
        XCTAssertFalse(player.isPlaying)
    }

    func testHandleTogglePlayPauseCommandPausesWhilePlaying() {
        let player = AudioPlayer()
        player.play(url: URL(string: "https://example.com/audio.mp3")!)

        let status = player.handleTogglePlayPauseCommand()

        XCTAssertEqual(status, .success)
        XCTAssertFalse(player.isPlaying)
    }

    func testHandleTogglePlayPauseCommandResumesWhilePaused() {
        let player = AudioPlayer()
        player.play(url: URL(string: "https://example.com/audio.mp3")!)
        player.pause()

        let status = player.handleTogglePlayPauseCommand()

        XCTAssertEqual(status, .success)
        XCTAssertTrue(player.isPlaying)
    }

    func testHandleSkipBackwardCommandSeeksBackByInterval() {
        let player = AudioPlayer()
        player.play(url: URL(string: "https://example.com/audio.mp3")!, startPosition: 100)

        let status = player.handleSkipBackwardCommand(interval: 15)

        XCTAssertEqual(status, .success)
        XCTAssertEqual(player.currentTime, 85)
    }

    func testHandleSkipBackwardCommandClampsToZero() {
        let player = AudioPlayer()
        player.play(url: URL(string: "https://example.com/audio.mp3")!, startPosition: 10)

        _ = player.handleSkipBackwardCommand(interval: 15)

        XCTAssertEqual(player.currentTime, 0)
    }

    func testHandleSkipForwardCommandSeeksForwardByInterval() {
        let player = AudioPlayer()
        player.play(url: URL(string: "https://example.com/audio.mp3")!, startPosition: 100)

        let status = player.handleSkipForwardCommand(interval: 30)

        XCTAssertEqual(status, .success)
        XCTAssertEqual(player.currentTime, 130)
    }

    func testHandleChangePlaybackPositionCommandSeeksToPosition() {
        let player = AudioPlayer()
        player.play(url: URL(string: "https://example.com/audio.mp3")!, startPosition: 10)

        let status = player.handleChangePlaybackPositionCommand(positionTime: 200)

        XCTAssertEqual(status, .success)
        XCTAssertEqual(player.currentTime, 200)
    }

    func testHandleSkipForwardCommandWithNoActiveItemReturnsNoActionableNowPlayingItem() {
        let player = AudioPlayer()

        XCTAssertEqual(player.handleSkipForwardCommand(interval: 30), .noActionableNowPlayingItem)
    }
}
