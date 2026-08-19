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
}
