import XCTest
@testable import Kuulla

final class AudioPlayerTests: XCTestCase {
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
}
