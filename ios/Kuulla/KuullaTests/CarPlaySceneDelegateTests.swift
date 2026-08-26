import XCTest
@testable import Kuulla

final class CarPlaySceneDelegateTests: XCTestCase {
    func testSortedSubscriptionsOrdersCaseInsensitivelyByTitle() {
        let subscriptions = [
            makeSubscription(showId: "1", showTitle: "zebra Cast"),
            makeSubscription(showId: "2", showTitle: "Aardvark Hour"),
            makeSubscription(showId: "3", showTitle: "middle Show"),
        ]

        let sorted = CarPlaySceneDelegate.sortedSubscriptions(subscriptions)

        XCTAssertEqual(sorted.map(\.showId), ["2", "3", "1"])
    }

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

    private func makeSubscription(showId: String, showTitle: String) -> Subscription {
        Subscription(
            id: "sub-\(showId)", userId: "user1", showId: showId, showTitle: showTitle, showAuthor: "Author",
            showArtworkUrl: nil, subscribedAt: Date())
    }

    private func makeEpisode(durationSeconds: TimeInterval?) -> Episode {
        let durationField = durationSeconds.map { "\"duration\":\"\(Int($0 / 3600)):\(Int($0 / 60) % 60):\(Int($0) % 60)\"," } ?? ""
        let json = """
        {"id":"ep1","showId":"show1","title":"Title",\(durationField)"audioUrl":"https://example.com/ep1.mp3"}
        """.data(using: .utf8)!
        return try! JSONDecoder().decode(Episode.self, from: json)
    }
}
