import XCTest
@testable import Kuulla

final class UnplayedCountsTests: XCTestCase {
    private func makeNewEpisode(id: String, showId: String, autoPlayed: Bool) -> NewEpisode {
        let json = """
        {
            "episode": {
                "id": "\(id)",
                "showId": "\(showId)",
                "title": "Episode \(id)",
                "audioUrl": "https://example.com/audio.mp3"
            },
            "autoPlayed": \(autoPlayed)
        }
        """.data(using: .utf8)!

        return try! JSONDecoder().decode(NewEpisode.self, from: json)
    }

    func testGroupsShowIdsByCount() {
        let counts = UnplayedCounts.compute(from: [
            makeNewEpisode(id: "e1", showId: "show-1", autoPlayed: false),
            makeNewEpisode(id: "e2", showId: "show-1", autoPlayed: false),
            makeNewEpisode(id: "e3", showId: "show-2", autoPlayed: false),
        ])

        XCTAssertEqual(counts["show-1"]?.unplayed, 2)
        XCTAssertEqual(counts["show-2"]?.unplayed, 1)
    }

    func testEmptyInputReturnsEmptyDictionary() {
        XCTAssertTrue(UnplayedCounts.compute(from: []).isEmpty)
    }

    func testShowIdNotInInputIsAbsentFromResult() {
        let counts = UnplayedCounts.compute(from: [makeNewEpisode(id: "e1", showId: "show-1", autoPlayed: false)])

        XCTAssertNil(counts["show-2"])
    }

    func testAutoPlayedEpisodesAreExcludedFromUnplayedCount() {
        let counts = UnplayedCounts.compute(from: [
            makeNewEpisode(id: "e1", showId: "show-1", autoPlayed: false),
            makeNewEpisode(id: "e2", showId: "show-1", autoPlayed: true),
            makeNewEpisode(id: "e3", showId: "show-1", autoPlayed: true),
        ])

        XCTAssertEqual(counts["show-1"]?.unplayed, 1)
    }

    func testShowWithOnlyAutoPlayedEpisodesIsAbsentFromResult() {
        let counts = UnplayedCounts.compute(from: [makeNewEpisode(id: "e1", showId: "show-1", autoPlayed: true)])

        XCTAssertNil(counts["show-1"])
    }

    func testHitCapReflectsRawCountNotFilteredCount() {
        let cap = UnplayedCounts.newEpisodesPerShowCap
        var rawEpisodes = (0..<cap).map { makeNewEpisode(id: "e\($0)", showId: "show-1", autoPlayed: true) }
        rawEpisodes.append(makeNewEpisode(id: "e-unplayed", showId: "show-1", autoPlayed: false))

        let counts = UnplayedCounts.compute(from: rawEpisodes)

        // Raw per-show count hit the server's page cap, even though only one episode is unplayed —
        // callers should treat unplayed as a lower bound rather than an exact count.
        XCTAssertEqual(counts["show-1"]?.unplayed, 1)
        XCTAssertEqual(counts["show-1"]?.hitCap, true)
    }

    func testHitCapIsFalseWhenRawCountIsUnderCap() {
        let counts = UnplayedCounts.compute(from: [makeNewEpisode(id: "e1", showId: "show-1", autoPlayed: false)])

        XCTAssertEqual(counts["show-1"]?.hitCap, false)
    }
}
