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

        // AudioPlayer.play() sets isPlaying synchronously right after handing the URL to
        // AVPlayer, so this only confirms the tap wired through to AudioPlayer and the button
        // reflects its state — not that the audio actually started buffering or playing. Genuine
        // playback verification would need AudioPlayer to expose real AVPlayer status, which it
        // doesn't today.
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 20))
    }
}
