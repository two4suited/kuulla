import XCTest
@testable import Kuulla

final class EpisodeListFilterTests: XCTestCase {
    private func makeEpisode(id: String, publishedAt: String) -> Episode {
        let json = """
        {
            "id": "\(id)",
            "showId": "show-1",
            "title": "Episode \(id)",
            "publishedAt": "\(publishedAt)",
            "audioUrl": "https://example.com/audio.mp3"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: text)!
        }
        return try! decoder.decode(Episode.self, from: json)
    }

    func testAllFilterReturnsEveryEpisode() {
        let episodes = [makeEpisode(id: "e1", publishedAt: "2024-01-02T00:00:00Z"), makeEpisode(id: "e2", publishedAt: "2024-01-01T00:00:00Z")]

        let result = EpisodeListFilter.apply(episodes: episodes, statuses: [:], filter: .all, sort: .newestFirst)

        XCTAssertEqual(result.map(\.id), ["e1", "e2"])
    }

    func testUnplayedFilterIncludesOnlyNewAndExcludesAutoPlayedInProgressAndPlayed() {
        let episodes = ["e1", "e2", "e3", "e4"].map { makeEpisode(id: $0, publishedAt: "2024-01-01T00:00:00Z") }
        let statuses: [String: EpisodeStatus] = [
            "e1": .new, "e2": .autoPlayed, "e3": .inProgress, "e4": .played,
        ]

        let result = EpisodeListFilter.apply(episodes: episodes, statuses: statuses, filter: .unplayed, sort: .newestFirst)

        XCTAssertEqual(Set(result.map(\.id)), ["e1"])
    }

    func testUnfinishedFilterIncludesNewAndInProgressButExcludesAutoPlayedAndPlayed() {
        let episodes = ["e1", "e2", "e3", "e4"].map { makeEpisode(id: $0, publishedAt: "2024-01-01T00:00:00Z") }
        let statuses: [String: EpisodeStatus] = [
            "e1": .new, "e2": .autoPlayed, "e3": .inProgress, "e4": .played,
        ]

        let result = EpisodeListFilter.apply(episodes: episodes, statuses: statuses, filter: .unfinished, sort: .newestFirst)

        XCTAssertEqual(Set(result.map(\.id)), ["e1", "e3"])
    }

    func testEpisodeWithNoStatusIsIncludedInUnfinishedFilter() {
        let episodes = [makeEpisode(id: "e1", publishedAt: "2024-01-01T00:00:00Z")]

        let result = EpisodeListFilter.apply(episodes: episodes, statuses: [:], filter: .unfinished, sort: .newestFirst)

        XCTAssertEqual(result.map(\.id), ["e1"])
    }

    func testInProgressFilterIncludesOnlyInProgressEpisodes() {
        let episodes = ["e1", "e2"].map { makeEpisode(id: $0, publishedAt: "2024-01-01T00:00:00Z") }
        let statuses: [String: EpisodeStatus] = ["e1": .inProgress, "e2": .played]

        let result = EpisodeListFilter.apply(episodes: episodes, statuses: statuses, filter: .inProgress, sort: .newestFirst)

        XCTAssertEqual(result.map(\.id), ["e1"])
    }

    func testEpisodeWithNoStatusIsTreatedAsUnplayed() {
        let episodes = [makeEpisode(id: "e1", publishedAt: "2024-01-01T00:00:00Z")]

        let result = EpisodeListFilter.apply(episodes: episodes, statuses: [:], filter: .unplayed, sort: .newestFirst)

        XCTAssertEqual(result.map(\.id), ["e1"])
    }

    func testOldestFirstReversesOrder() {
        let episodes = [makeEpisode(id: "e1", publishedAt: "2024-01-02T00:00:00Z"), makeEpisode(id: "e2", publishedAt: "2024-01-01T00:00:00Z")]

        let result = EpisodeListFilter.apply(episodes: episodes, statuses: [:], filter: .all, sort: .oldestFirst)

        XCTAssertEqual(result.map(\.id), ["e2", "e1"])
    }

    func testArchivedEpisodesAreExcludedFromEveryFilterTab() {
        let episodes = ["e1", "e2", "e3"].map { makeEpisode(id: $0, publishedAt: "2024-01-01T00:00:00Z") }
        let statuses: [String: EpisodeStatus] = ["e1": .played, "e2": .played, "e3": .new]

        let allResult = EpisodeListFilter.apply(
            episodes: episodes, statuses: statuses, filter: .all, sort: .newestFirst, archived: ["e1"])
        let unplayedResult = EpisodeListFilter.apply(
            episodes: episodes, statuses: statuses, filter: .unplayed, sort: .newestFirst, archived: ["e3"])

        XCTAssertEqual(Set(allResult.map(\.id)), ["e2", "e3"])
        XCTAssertTrue(unplayedResult.isEmpty)
    }
}
