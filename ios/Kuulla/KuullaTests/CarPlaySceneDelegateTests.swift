import XCTest
@testable import Kuulla

final class CarPlaySceneDelegateTests: XCTestCase {
    func testEpisodeDetailTextCombinesDurationAndStatus() {
        let episode = makeEpisode(durationSeconds: 90)

        let text = CarPlaySceneDelegate.episodeDetailText(episode: episode, status: .inProgress)

        XCTAssertEqual(text, "\(EpisodeFormatting.formatDuration(90)) · In Progress")
    }

    func testEpisodeDetailTextOmitsMissingDuration() {
        let episode = makeEpisode(durationSeconds: nil)

        let text = CarPlaySceneDelegate.episodeDetailText(episode: episode, status: .new)

        XCTAssertEqual(text, "New")
    }

    func testNextPlaybackSpeedCyclesUpward() {
        XCTAssertEqual(CarPlaySceneDelegate.nextPlaybackSpeed(after: 1.0), 1.2)
    }

    func testNextPlaybackSpeedWrapsAfterFastest() {
        XCTAssertEqual(CarPlaySceneDelegate.nextPlaybackSpeed(after: 3.0), 0.5)
    }

    func testNextPlaybackSpeedStartsFromSlowestForUnknownValue() {
        XCTAssertEqual(CarPlaySceneDelegate.nextPlaybackSpeed(after: 1.35), 0.5)
    }

    private func makeEpisode(durationSeconds: TimeInterval?) -> Episode {
        let durationField = durationSeconds.map { "\"duration\":\"\(Int($0 / 3600)):\(Int($0 / 60) % 60):\(Int($0) % 60)\"," } ?? ""
        let json = """
        {"id":"ep1","showId":"show1","title":"Title",\(durationField)"audioUrl":"https://example.com/ep1.mp3"}
        """.data(using: .utf8)!
        return try! JSONDecoder().decode(Episode.self, from: json)
    }
}
