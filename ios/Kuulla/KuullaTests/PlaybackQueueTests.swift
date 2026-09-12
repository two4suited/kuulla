import XCTest
@testable import Kuulla

// The network / AudioPlayer parts of PlaybackQueue mirror CarPlaySceneDelegate's already-covered
// playback path; what's genuinely new here is the "what plays next" decision and the setting
// resolution order, which are pure functions — that's what these exercise (mirroring
// AudioPlayerTests' shouldTriggerOutroSkip cases).
final class PlaybackQueueTests: XCTestCase {
    private func items(_ ids: [String]) -> [PlaybackQueue.QueueItem] {
        ids.map { PlaybackQueue.QueueItem(showId: "show-\($0)", episodeId: $0) }
    }

    // MARK: - .nextInList

    func testNextInListReturnsTheFollowingEpisode() {
        let next = PlaybackQueue.nextItem(after: "b", in: items(["a", "b", "c"]), behavior: .nextInList)
        XCTAssertEqual(next, PlaybackQueue.QueueItem(showId: "show-c", episodeId: "c"))
    }

    func testNextInListIsNilAtTheEndOfTheQueue() {
        XCTAssertNil(PlaybackQueue.nextItem(after: "c", in: items(["a", "b", "c"]), behavior: .nextInList))
    }

    func testNextInListIsNilForASingleItemQueue() {
        XCTAssertNil(PlaybackQueue.nextItem(after: "only", in: items(["only"]), behavior: .nextInList))
    }

    func testNextInListIsNilWhenTheFinishedEpisodeIsNoLongerInTheSnapshot() {
        // Reorder / removal race: the finished episode was pulled from the list under us — stop
        // rather than guessing which item is "next".
        XCTAssertNil(PlaybackQueue.nextItem(after: "gone", in: items(["a", "b", "c"]), behavior: .nextInList))
    }

    func testNextInListIsNilForAnEmptyQueue() {
        XCTAssertNil(PlaybackQueue.nextItem(after: "a", in: [], behavior: .nextInList))
    }

    // MARK: - .topOfList

    func testTopOfListReturnsTheFirstItemThatIsNotTheFinishedOne() {
        let next = PlaybackQueue.nextItem(after: "a", in: items(["a", "b", "c"]), behavior: .topOfList)
        XCTAssertEqual(next, PlaybackQueue.QueueItem(showId: "show-b", episodeId: "b"))
    }

    func testTopOfListSkipsTheFinishedItemEvenWhenItStillLeadsTheSnapshot() {
        // The list may not have dropped the finished episode yet (a dynamic playlist's next
        // recompute, or a show list that hasn't refreshed) — the finished item itself is never
        // "top of list" again.
        let next = PlaybackQueue.nextItem(after: "b", in: items(["a", "b", "c"]), behavior: .topOfList)
        XCTAssertEqual(next, PlaybackQueue.QueueItem(showId: "show-a", episodeId: "a"))
    }

    func testTopOfListIsNilForASingleItemQueue() {
        XCTAssertNil(PlaybackQueue.nextItem(after: "only", in: items(["only"]), behavior: .topOfList))
    }

    func testTopOfListIsNilForAnEmptyQueue() {
        XCTAssertNil(PlaybackQueue.nextItem(after: "a", in: [], behavior: .topOfList))
    }

    // MARK: - .stop

    func testStopNeverAdvances() {
        XCTAssertNil(PlaybackQueue.nextItem(after: "a", in: items(["a", "b", "c"]), behavior: .stop))
    }

    // MARK: - resolve (playlist -> show -> global)

    func testResolvePrefersPlaylistOverrideOverShowOverrideAndGlobal() {
        let resolved = PlaybackQueue.resolve(playlistOverride: .topOfList, showOverride: .stop, global: .nextInList)
        XCTAssertEqual(resolved, .topOfList)
    }

    func testResolvePrefersShowOverrideOverGlobalWhenNoPlaylistOverride() {
        let resolved = PlaybackQueue.resolve(playlistOverride: nil, showOverride: .stop, global: .nextInList)
        XCTAssertEqual(resolved, .stop)
    }

    func testResolveFallsBackToGlobalWhenNoOverridesAreSet() {
        let resolved = PlaybackQueue.resolve(playlistOverride: nil, showOverride: nil, global: .topOfList)
        XCTAssertEqual(resolved, .topOfList)
    }
}
