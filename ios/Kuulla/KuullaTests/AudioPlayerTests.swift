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

    // MARK: - Now Playing context / in-app bar (#542)

    func testPlayWithContextExposesItForTheNowPlayingBar() {
        let player = AudioPlayer()

        player.play(
            url: URL(string: "https://example.com/audio.mp3")!,
            context: NowPlayingContext(showId: "show-1", episodeId: "ep-1", playlistId: "pl-1"),
            metadata: NowPlayingMetadata(title: "Episode", showTitle: "Show", artworkURL: nil))

        XCTAssertEqual(player.nowPlayingContext, NowPlayingContext(showId: "show-1", episodeId: "ep-1", playlistId: "pl-1"))
        XCTAssertEqual(player.nowPlayingMetadata?.title, "Episode")
    }

    func testPlayWithoutContextLeavesNowPlayingContextNil() {
        let player = AudioPlayer()

        player.play(url: URL(string: "https://example.com/audio.mp3")!)

        XCTAssertNil(player.nowPlayingContext)
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

    // MARK: - Interruptions (#612)

    // Regression test for #612 staying broken after the first fix (#613): an interruption ending
    // without AVAudioSessionInterruptionOptionKey's .shouldResume flag set — which the system does
    // for plenty of brief, ambient interruptions (e.g. a notification's system sound), not just
    // ones where resuming would be wrong — must still resume playback that was actually playing
    // beforehand. handleInterruption is the internal seam standing in for a real
    // AVAudioSession.interruptionNotification post, which can't be triggered deterministically here.
    func testInterruptionEndResumesEvenWithoutShouldResumeOption() {
        let player = AudioPlayer()
        player.play(url: URL(string: "https://example.com/audio.mp3")!)

        player.handleInterruption(type: .began)
        XCTAssertFalse(player.isPlaying)

        player.handleInterruption(type: .ended)

        XCTAssertTrue(player.isPlaying)
    }

    func testInterruptionEndDoesNotResumeIfNotPlayingBeforehand() {
        let player = AudioPlayer()
        player.play(url: URL(string: "https://example.com/audio.mp3")!)
        player.pause()

        player.handleInterruption(type: .began)
        player.handleInterruption(type: .ended)

        XCTAssertFalse(player.isPlaying)
    }

    // #710: auto-resuming after an interruption rewinds a few seconds so the sentence
    // interrupted by the call/nav prompt isn't lost (AntennaPod "rewind on resume").
    func testInterruptionEndRewindsPlaybackByAFewSeconds() {
        let player = AudioPlayer()
        player.play(url: URL(string: "https://example.com/audio.mp3")!)
        _ = player.handleSkipForwardCommand(interval: 30)
        XCTAssertEqual(player.currentTime, 30)

        player.handleInterruption(type: .began)
        player.handleInterruption(type: .ended)

        XCTAssertEqual(player.currentTime, 27)
        XCTAssertTrue(player.isPlaying)
    }

    // The rewind must not push currentTime negative for an interruption that lands moments
    // into the episode.
    func testInterruptionEndRewindClampsToZeroNearTheStart() {
        let player = AudioPlayer()
        player.play(url: URL(string: "https://example.com/audio.mp3")!)
        _ = player.handleSkipForwardCommand(interval: 1)
        XCTAssertEqual(player.currentTime, 1)

        player.handleInterruption(type: .began)
        player.handleInterruption(type: .ended)

        XCTAssertEqual(player.currentTime, 0)
        XCTAssertTrue(player.isPlaying)
    }

    // Control Center remains reachable during some interruption types, so a manual pause can land
    // between .began and .ended. That pause must stick — without clearing
    // wasPlayingBeforeInterruption, .ended would still see it as true (from before the
    // interruption began) and resume playback the user just explicitly stopped.
    func testManualPauseDuringInterruptionIsNotOverriddenByInterruptionEnd() {
        let player = AudioPlayer()
        player.play(url: URL(string: "https://example.com/audio.mp3")!)

        player.handleInterruption(type: .began)
        player.pause()
        player.handleInterruption(type: .ended)

        XCTAssertFalse(player.isPlaying)
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

    // MARK: - Pending-position seek vs. a fast skip/scrub (#315)

    // The initial resume-seek's completion must only start playback when it actually lands
    // (finished == true) — a cancelled seek fires its completion too (finished == false), and
    // acting on it would start audio at a stale target.
    func testGoverningSeekCompletionAppliesRateOnlyWhenFinished() {
        let player = AudioPlayer()
        player.play(url: URL(string: "https://example.com/audio.mp3")!, startPosition: 120, playbackSpeed: 1.5)
        let generation = player.currentSeekGeneration

        player.completeGoverningSeek(generation: generation, finished: false)
        XCTAssertEqual(player.currentPlayerRate, 0)
        XCTAssertTrue(player.isPlaying)

        player.completeGoverningSeek(generation: generation, finished: true)
        XCTAssertEqual(player.currentPlayerRate, 1.5)
    }

    // A skip fired while the resume-seek is still pending supersedes it: the earlier seek's
    // completion — even one that reports finished == true — must not start playback, because its
    // generation is now stale. Only the skip's own seek governs playback start.
    func testGoverningSeekCompletionIgnoresStaleGenerationFromASupersededSeek() {
        let player = AudioPlayer()
        player.play(url: URL(string: "https://example.com/audio.mp3")!, startPosition: 120, playbackSpeed: 1.5)
        let staleGeneration = player.currentSeekGeneration

        _ = player.handleSkipForwardCommand(interval: 30)
        XCTAssertEqual(player.currentTime, 150)

        player.completeGoverningSeek(generation: staleGeneration, finished: true)
        XCTAssertEqual(player.currentPlayerRate, 0)
        XCTAssertTrue(player.isPlaying)

        player.completeGoverningSeek(generation: player.currentSeekGeneration, finished: true)
        XCTAssertEqual(player.currentPlayerRate, 1.5)
    }

    // End to end: skipping during the pending resume-seek keeps playback deferred (rate 0) until
    // the superseding seek lands, rather than audibly starting at the old position.
    func testSkipDuringPendingSeekKeepsPlaybackDeferredUntilTheNewSeekLands() {
        let player = AudioPlayer()
        player.play(url: URL(string: "https://example.com/audio.mp3")!, startPosition: 120)

        _ = player.handleSkipBackwardCommand(interval: 15)

        XCTAssertEqual(player.currentTime, 105)
        XCTAssertEqual(player.currentPlayerRate, 0)
        XCTAssertTrue(player.isPlaying)
    }

    // A pause landing during the pending seek clears it — a governing-seek completion that fires
    // afterwards must not resume playback out from under the user.
    func testGoverningSeekCompletionIsIgnoredAfterPauseDuringPendingSeek() {
        let player = AudioPlayer()
        player.play(url: URL(string: "https://example.com/audio.mp3")!, startPosition: 120)
        let generation = player.currentSeekGeneration
        player.pause()

        player.completeGoverningSeek(generation: generation, finished: true)

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

    // MARK: - Sleep timer (#207)

    func testStartSleepTimerSetsRemainingSecondsFromMinutes() {
        let player = AudioPlayer()

        player.startSleepTimer(minutes: 15)

        XCTAssertEqual(player.sleepTimerRemainingSeconds, 900)
        XCTAssertFalse(player.sleepTimerEndOfEpisodeEnabled)
    }

    func testTickSleepTimerDecrementsRemainingSecondsBySecond() {
        let player = AudioPlayer()
        player.startSleepTimer(minutes: 1)

        player.tickSleepTimer()

        XCTAssertEqual(player.sleepTimerRemainingSeconds, 59)
    }

    func testTickSleepTimerPausesPlaybackAndClearsCountdownToNilOnceItReachesZero() {
        let player = AudioPlayer()
        player.play(url: URL(string: "https://example.com/audio.mp3")!)
        player.startSleepTimer(minutes: 0)
        // minutes: 0 seeds 0 remaining seconds directly (no whole minute to count down from),
        // so a single tick is what actually crosses the zero threshold and fires expiry.

        player.tickSleepTimer()

        XCTAssertFalse(player.isPlaying)
        // nil (not 0) once expired — nil is the sole "no countdown active" contract every other
        // caller (adjustSleepTimer, UI) relies on; leaving it at 0 would make an expired timer
        // still look active.
        XCTAssertNil(player.sleepTimerRemainingSeconds)
    }

    func testTickSleepTimerIsANoOpWhenNoCountdownIsActive() {
        let player = AudioPlayer()
        player.play(url: URL(string: "https://example.com/audio.mp3")!)

        player.tickSleepTimer()

        XCTAssertTrue(player.isPlaying)
        XCTAssertNil(player.sleepTimerRemainingSeconds)
    }

    func testAdjustSleepTimerAddsMinutesToRunningCountdown() {
        let player = AudioPlayer()
        player.startSleepTimer(minutes: 10)

        player.adjustSleepTimer(byMinutes: 5)

        XCTAssertEqual(player.sleepTimerRemainingSeconds, 900)
    }

    func testAdjustSleepTimerSubtractsMinutesAndClampsAtZeroRatherThanGoingNegative() {
        let player = AudioPlayer()
        player.startSleepTimer(minutes: 2)

        player.adjustSleepTimer(byMinutes: -10)

        XCTAssertEqual(player.sleepTimerRemainingSeconds, 0)
    }

    func testAdjustSleepTimerIsANoOpAfterTheCountdownHasAlreadyExpired() {
        let player = AudioPlayer()
        player.startSleepTimer(minutes: 0)
        player.tickSleepTimer()

        player.adjustSleepTimer(byMinutes: 5)

        // Must stay nil, not resurrect a 5-minute countdown with no Timer left running it.
        XCTAssertNil(player.sleepTimerRemainingSeconds)
    }

    func testAdjustSleepTimerIsANoOpWhenNoCountdownIsActive() {
        let player = AudioPlayer()

        player.adjustSleepTimer(byMinutes: 5)

        XCTAssertNil(player.sleepTimerRemainingSeconds)
    }

    func testCancelSleepTimerClearsCountdown() {
        let player = AudioPlayer()
        player.startSleepTimer(minutes: 10)

        player.cancelSleepTimer()

        XCTAssertNil(player.sleepTimerRemainingSeconds)
        XCTAssertFalse(player.sleepTimerEndOfEpisodeEnabled)
    }

    func testStartSleepTimerForEndOfEpisodeEnablesFlagAndClearsAnyCountdown() {
        let player = AudioPlayer()
        player.startSleepTimer(minutes: 10)

        player.startSleepTimerForEndOfEpisode()

        XCTAssertTrue(player.sleepTimerEndOfEpisodeEnabled)
        XCTAssertNil(player.sleepTimerRemainingSeconds)
    }

    func testStartSleepTimerReplacesAnActiveEndOfEpisodeMode() {
        let player = AudioPlayer()
        player.startSleepTimerForEndOfEpisode()

        player.startSleepTimer(minutes: 5)

        XCTAssertFalse(player.sleepTimerEndOfEpisodeEnabled)
        XCTAssertEqual(player.sleepTimerRemainingSeconds, 300)
    }

    func testCancelSleepTimerClearsEndOfEpisodeMode() {
        let player = AudioPlayer()
        player.startSleepTimerForEndOfEpisode()

        player.cancelSleepTimer()

        XCTAssertFalse(player.sleepTimerEndOfEpisodeEnabled)
    }

    func testFireOnDidFinishPlayingSuppressesCallbackWhenEndOfEpisodeSleepTimerIsArmed() {
        let player = AudioPlayer()
        let url = URL(string: "https://example.com/audio.mp3")!
        player.startSleepTimerForEndOfEpisode()
        var callbackInvoked = false
        player.onDidFinishPlaying = { _ in callbackInvoked = true }

        player.fireOnDidFinishPlayingUnlessSleepTimerStopsHere(url: url)

        XCTAssertFalse(callbackInvoked)
        // The mode is consumed by firing once — a second finish (e.g. the next episode
        // completing naturally) must not still be silently suppressed.
        XCTAssertFalse(player.sleepTimerEndOfEpisodeEnabled)
    }

    // The sleep timer stopping here means playback won't advance to the preloaded episode at
    // all — leaving its second AVPlayer/network connection open would just waste resources.
    func testFireOnDidFinishPlayingDiscardsPendingPreloadWhenEndOfEpisodeSleepTimerStopsHere() {
        let player = AudioPlayer()
        let url = URL(string: "https://example.com/audio.mp3")!
        player.play(url: url)
        let nextURL = URL(string: "https://example.com/b.mp3")!
        player.preloadNext(url: nextURL)
        player.markPendingPreloadReady()
        player.startSleepTimerForEndOfEpisode()

        player.fireOnDidFinishPlayingUnlessSleepTimerStopsHere(url: url)

        XCTAssertFalse(player.hasPendingPreload(for: nextURL))
    }

    func testFireOnDidFinishPlayingInvokesCallbackWhenNoEndOfEpisodeSleepTimerIsArmed() {
        let player = AudioPlayer()
        let url = URL(string: "https://example.com/audio.mp3")!
        var receivedURL: URL?
        player.onDidFinishPlaying = { receivedURL = $0 }

        player.fireOnDidFinishPlayingUnlessSleepTimerStopsHere(url: url)

        XCTAssertEqual(receivedURL, url)
    }

    // MARK: - Gapless preload (#683)

    func testShouldFireApproachingEndIsFalseUntilRemainingPlaybackCrossesTheLeadTime() {
        XCTAssertFalse(AudioPlayer.shouldFireApproachingEnd(currentTime: 585, duration: 600, leadSeconds: 10))
        XCTAssertTrue(AudioPlayer.shouldFireApproachingEnd(currentTime: 590, duration: 600, leadSeconds: 10))
        XCTAssertTrue(AudioPlayer.shouldFireApproachingEnd(currentTime: 595, duration: 600, leadSeconds: 10))
    }

    func testShouldFireApproachingEndIsFalseBeforeDurationIsKnown() {
        XCTAssertFalse(AudioPlayer.shouldFireApproachingEnd(currentTime: 0, duration: 0, leadSeconds: 10))
    }

    // A preload that has reached readyToPlay (simulated via markPendingPreloadReady, since a fake
    // network URL's AVPlayerItem never actually resolves in a unit test) and is still for the
    // requested URL swaps in as the active player — currentURL, isPlaying, and the applied rate
    // all reflect the preloaded session immediately, exactly like a fresh play() would.
    func testSwapToPendingPreloadReplacesTheActivePlayerWhenReady() {
        let player = AudioPlayer()
        player.play(url: URL(string: "https://example.com/a.mp3")!)
        let nextURL = URL(string: "https://example.com/b.mp3")!

        player.preloadNext(url: nextURL, playbackSpeed: 1.25)
        XCTAssertFalse(player.hasPendingPreload(for: nextURL), "not ready until the item's status reaches readyToPlay")
        player.markPendingPreloadReady()
        XCTAssertTrue(player.hasPendingPreload(for: nextURL))

        let swapped = player.swapToPendingPreload()

        XCTAssertTrue(swapped)
        XCTAssertEqual(player.currentURL, nextURL)
        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(player.currentPlayerRate, 1.25)
        // The preload is consumed by a successful swap — nothing left to swap to a second time.
        XCTAssertFalse(player.hasPendingPreload(for: nextURL))
    }

    // An unready preload (never marked ready — mirrors a preload whose network fetch is still in
    // flight when the current item actually ends) must not be swapped in; the caller is expected
    // to fall back to the full, slow play() path instead.
    func testSwapToPendingPreloadFailsWhenTheItemIsNotYetReady() {
        let player = AudioPlayer()
        let currentURL = URL(string: "https://example.com/a.mp3")!
        player.play(url: currentURL)
        player.preloadNext(url: URL(string: "https://example.com/b.mp3")!)

        let swapped = player.swapToPendingPreload()

        XCTAssertFalse(swapped)
        XCTAssertEqual(player.currentURL, currentURL, "an unready preload must not disturb the currently-playing session")
    }

    func testSwapToPendingPreloadFailsWhenNoPreloadWasEverStarted() {
        let player = AudioPlayer()
        player.play(url: URL(string: "https://example.com/a.mp3")!)

        XCTAssertFalse(player.swapToPendingPreload())
    }

    // A stale preload — one prepared for an episode the user then skipped past by starting a
    // completely different manual play() session (the same shape as "the user skipped to episode
    // C before A finished") — must be discarded rather than swapped in later. play() always
    // invalidates any outstanding preload for exactly this reason (#663/#670's fragility lives in
    // this same finish-handling path, so a stale preload silently winning here would be a
    // regression of the same kind).
    func testAFreshPlayCallDiscardsAnyOutstandingPreloadEvenIfLaterMarkedReady() {
        let player = AudioPlayer()
        player.play(url: URL(string: "https://example.com/a.mp3")!)
        let staleNextURL = URL(string: "https://example.com/b.mp3")!
        player.preloadNext(url: staleNextURL)
        player.markPendingPreloadReady()

        let newSessionURL = URL(string: "https://example.com/c.mp3")!
        player.play(url: newSessionURL)

        XCTAssertFalse(player.hasPendingPreload(for: staleNextURL))
        XCTAssertFalse(player.swapToPendingPreload())
        XCTAssertEqual(player.currentURL, newSessionURL)
    }

    func testHasPendingPreloadIsFalseForADifferentURLThanTheOneBeingPreloaded() {
        let player = AudioPlayer()
        player.play(url: URL(string: "https://example.com/a.mp3")!)
        let preloadedURL = URL(string: "https://example.com/b.mp3")!
        player.preloadNext(url: preloadedURL)
        player.markPendingPreloadReady()

        XCTAssertFalse(player.hasPendingPreload(for: URL(string: "https://example.com/other.mp3")!))
        XCTAssertTrue(player.hasPendingPreload(for: preloadedURL))
    }

    func testDiscardPendingPreloadClearsAReadyPreload() {
        let player = AudioPlayer()
        player.play(url: URL(string: "https://example.com/a.mp3")!)
        let nextURL = URL(string: "https://example.com/b.mp3")!
        player.preloadNext(url: nextURL)
        player.markPendingPreloadReady()

        player.discardPendingPreload()

        XCTAssertFalse(player.hasPendingPreload(for: nextURL))
        XCTAssertFalse(player.swapToPendingPreload())
    }

    // The preloaded session carries its own settings (speed, start position) independently of
    // whatever the outgoing session was configured with.
    func testSwapToPendingPreloadAppliesThePreloadedSessionsOwnStartPosition() {
        let player = AudioPlayer()
        player.play(url: URL(string: "https://example.com/a.mp3")!, playbackSpeed: 2.0)
        let nextURL = URL(string: "https://example.com/b.mp3")!
        player.preloadNext(url: nextURL, startPosition: 42, playbackSpeed: 1.0)
        player.markPendingPreloadReady()

        player.swapToPendingPreload()

        XCTAssertEqual(player.currentTime, 42)
        XCTAssertEqual(player.currentPlayerRate, 1.0)
    }

    func testFireOnDidFinishPlayingInvokesCallbackWhenADurationSleepTimerIsStillRunning() {
        // A duration-based countdown (as opposed to "end of episode" mode) has nothing to do
        // with whether this particular episode just finished — it must not suppress the finish
        // callback just because a countdown happens to still be active.
        let player = AudioPlayer()
        let url = URL(string: "https://example.com/audio.mp3")!
        player.startSleepTimer(minutes: 10)
        var callbackInvoked = false
        player.onDidFinishPlaying = { _ in callbackInvoked = true }

        player.fireOnDidFinishPlayingUnlessSleepTimerStopsHere(url: url)

        XCTAssertTrue(callbackInvoked)
    }

    // MARK: - Watch now-playing snapshot (#582)

    func testCurrentWatchNowPlayingStateReflectsContextMetadataAndPlaybackState() {
        let player = AudioPlayer()

        player.play(
            url: URL(string: "https://example.com/audio.mp3")!, startPosition: 30,
            context: NowPlayingContext(showId: "show-1", episodeId: "ep-1", playlistId: nil),
            metadata: NowPlayingMetadata(title: "Episode", showTitle: "Show", artworkURL: nil))

        let state = player.currentWatchNowPlayingState()

        XCTAssertEqual(state?.episodeId, "ep-1")
        XCTAssertEqual(state?.showId, "show-1")
        XCTAssertEqual(state?.title, "Episode")
        XCTAssertEqual(state?.showTitle, "Show")
        XCTAssertEqual(state?.position, 30)
        XCTAssertEqual(state?.isPlaying, true)
    }

    func testCurrentWatchNowPlayingStateIsNilWithoutContext() {
        let player = AudioPlayer()

        player.play(
            url: URL(string: "https://example.com/audio.mp3")!,
            metadata: NowPlayingMetadata(title: "Episode", showTitle: nil, artworkURL: nil))

        XCTAssertNil(player.currentWatchNowPlayingState())
    }

    func testCurrentWatchNowPlayingStateReflectsPauseAndSeek() {
        let player = AudioPlayer()
        player.play(
            url: URL(string: "https://example.com/audio.mp3")!,
            context: NowPlayingContext(showId: "show-1", episodeId: "ep-1", playlistId: nil),
            metadata: NowPlayingMetadata(title: "Episode", showTitle: nil, artworkURL: nil))

        player.pause()
        XCTAssertEqual(player.currentWatchNowPlayingState()?.isPlaying, false)

        player.seek(to: 75)
        XCTAssertEqual(player.currentWatchNowPlayingState()?.position, 75)
    }

    func testDownsampledArtworkThumbnailProducesSmallerJPEGData() {
        let size = CGSize(width: 600, height: 600)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        let artwork = MPMediaItemArtwork(boundsSize: size) { _ in image }

        let thumbnail = AudioPlayer.downsampledArtworkThumbnail(artwork, maxDimension: 80)

        XCTAssertNotNil(thumbnail)
        // JPEG magic bytes (0xFFD8) confirm this is actually encoded/compressed, not the raw
        // full-size image passed through untouched.
        XCTAssertEqual(thumbnail?.prefix(2), Data([0xFF, 0xD8]))
        XCTAssertLessThan(thumbnail!.count, image.pngData()!.count)
    }
}
