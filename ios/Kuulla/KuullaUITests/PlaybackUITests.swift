import XCTest

// Covers issue #61's playback flow: search -> show -> episode -> play a real audio file end to
// end. Mirrors Kuulla.Web.E2E's BrowseAndPlaybackTests in spirit (real network, real audio,
// asserting on player state rather than mocking).
final class PlaybackUITests: KuullaUITestCase {
    func testOpenEpisode_AndPlayAudio() {
        signInAsTestUser()
        searchAndOpenFirstShow()

        // ShowDetailView's episode list only appears once the show and its first page of
        // episodes have both loaded.
        let firstEpisode = app.descendants(matching: .any)["episode-row"].firstMatch
        XCTAssertTrue(firstEpisode.waitForExistence(timeout: 20))
        firstEpisode.tap()

        let playButton = app.buttons["Play"]
        XCTAssertTrue(playButton.waitForExistence(timeout: 15))
        playButton.tap()

        // AudioPlayer.play() starts an AVPlayer against a real episode audio URL; the button's
        // label flips to "Pause" once AudioPlayer.isPlaying observes playback actually started.
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 20))
    }
}
