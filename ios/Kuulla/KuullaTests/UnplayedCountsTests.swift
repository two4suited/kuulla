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

    func testHitCapIsFalseWhenRawCountHitsCapButMostAreAutoPlayed() {
        // The unlistened-episode-limit enforcement job auto-marks every episode beyond a user's
        // limit as played across a show's *entire* back catalog, not just this fetched page — so a
        // raw page full of auto-played episodes plus a couple of genuinely unplayed ones means
        // exactly that many are unplayed, full stop. There's no larger unplayed count hiding beyond
        // the page cap in this case, so hitCap must be false here even though the raw count hit
        // newEpisodesPerShowCap.
        let cap = UnplayedCounts.newEpisodesPerShowCap
        var rawEpisodes = (0..<(cap - 1)).map { makeNewEpisode(id: "e\($0)", showId: "show-1", autoPlayed: true) }
        rawEpisodes.append(makeNewEpisode(id: "e-unplayed", showId: "show-1", autoPlayed: false))

        let counts = UnplayedCounts.compute(from: rawEpisodes)

        XCTAssertEqual(counts["show-1"]?.unplayed, 1)
        XCTAssertEqual(counts["show-1"]?.hitCap, false)
    }

    func testHitCapIsTrueWhenUnplayedCountItselfHitsCap() {
        // Every fetched item for the show is unplayed (nothing auto-played within the page), so we
        // can't tell whether more genuinely-unplayed episodes exist beyond this page — hitCap should
        // be true.
        let cap = UnplayedCounts.newEpisodesPerShowCap
        let rawEpisodes = (0..<cap).map { makeNewEpisode(id: "e\($0)", showId: "show-1", autoPlayed: false) }

        let counts = UnplayedCounts.compute(from: rawEpisodes)

        XCTAssertEqual(counts["show-1"]?.unplayed, cap)
        XCTAssertEqual(counts["show-1"]?.hitCap, true)
    }

    func testHitCapIsFalseWhenRawCountIsUnderCap() {
        let counts = UnplayedCounts.compute(from: [makeNewEpisode(id: "e1", showId: "show-1", autoPlayed: false)])

        XCTAssertEqual(counts["show-1"]?.hitCap, false)
    }
}
