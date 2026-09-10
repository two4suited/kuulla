import XCTest
@testable import Kuulla

// The network / AudioPlayer parts of PlaybackQueue mirror CarPlaySceneDelegate's already-covered
// playback path; what's genuinely new here is the "what plays next" decision, which is a pure
// function — that's what these exercise (mirroring AudioPlayerTests' shouldTriggerOutroSkip
// cases).
final class PlaybackQueueTests: XCTestCase {
    private func items(_ ids: [String]) -> [PlaybackQueue.QueueItem] {
        ids.map { PlaybackQueue.QueueItem(showId: "show-\($0)", episodeId: $0) }
    }

    func testNextItemReturnsTheFollowingEpisode() {
        let next = PlaybackQueue.nextItem(after: "b", in: items(["a", "b", "c"]))
        XCTAssertEqual(next, PlaybackQueue.QueueItem(showId: "show-c", episodeId: "c"))
    }

    func testNextItemIsNilAtTheEndOfTheQueue() {
        XCTAssertNil(PlaybackQueue.nextItem(after: "c", in: items(["a", "b", "c"])))
    }

    func testNextItemIsNilForASingleItemQueue() {
        XCTAssertNil(PlaybackQueue.nextItem(after: "only", in: items(["only"])))
    }

    func testNextItemIsNilWhenTheFinishedEpisodeIsNoLongerInTheSnapshot() {
        // Reorder / removal race: the finished episode was pulled from the list under us — stop
        // rather than guessing which item is "next".
        XCTAssertNil(PlaybackQueue.nextItem(after: "gone", in: items(["a", "b", "c"])))
    }

    func testNextItemIsNilForAnEmptyQueue() {
        XCTAssertNil(PlaybackQueue.nextItem(after: "a", in: []))
    }
}
