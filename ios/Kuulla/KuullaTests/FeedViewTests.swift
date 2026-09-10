import XCTest
@testable import Kuulla

final class FeedViewTests: XCTestCase {
    func testAlreadyDownloadedEpisodeNeverAutoDownloadsRegardlessOfSettings() {
        for status in [DownloadStatus.downloading, .complete, .failed] {
            XCTAssertFalse(FeedView.shouldAutoDownload(downloadStatus: status, showOverride: true, globalDefault: true))
        }
    }

    func testNoOverrideFallsBackToGlobalDefaultTrue() {
        XCTAssertTrue(FeedView.shouldAutoDownload(downloadStatus: nil, showOverride: nil, globalDefault: true))
    }

    func testNoOverrideFallsBackToGlobalDefaultFalse() {
        XCTAssertFalse(FeedView.shouldAutoDownload(downloadStatus: nil, showOverride: nil, globalDefault: false))
    }

    func testShowOverrideTrueWinsOverGlobalDefaultFalse() {
        XCTAssertTrue(FeedView.shouldAutoDownload(downloadStatus: nil, showOverride: true, globalDefault: false))
    }

    func testShowOverrideFalseWinsOverGlobalDefaultTrue() {
        XCTAssertFalse(FeedView.shouldAutoDownload(downloadStatus: nil, showOverride: false, globalDefault: true))
    }

    // MARK: displayItems (#534)

    private func newEpisode(id: String, publishedAt: Date?, autoPlayed: Bool) -> NewEpisode {
        let episode = Episode(
            id: id, showId: "show1", title: "Episode \(id)", publishedAt: publishedAt, duration: nil,
            audioUrl: "https://example.com/\(id).mp3", description: nil, bitrateKbps: nil,
            fileSizeBytes: nil, chapters: nil, transcriptUrl: nil, transcriptType: nil)
        return NewEpisode(episode: episode, autoPlayed: autoPlayed, showTitle: "Show", showArtworkUrl: nil)
    }

    func testDisplayItemsFiltersAutoPlayedAndSortsNewestFirst() {
        let older = newEpisode(id: "old", publishedAt: Date(timeIntervalSince1970: 1_000), autoPlayed: false)
        let newer = newEpisode(id: "new", publishedAt: Date(timeIntervalSince1970: 2_000), autoPlayed: false)
        let auto = newEpisode(id: "auto", publishedAt: Date(timeIntervalSince1970: 3_000), autoPlayed: true)

        let result = FeedView.displayItems(from: [older, auto, newer])

        XCTAssertEqual(result.map(\.episode.id), ["new", "old"])
    }

    func testDisplayItemsPutsMissingPublishDateLast() {
        let dated = newEpisode(id: "dated", publishedAt: Date(timeIntervalSince1970: 1_000), autoPlayed: false)
        let undated = newEpisode(id: "undated", publishedAt: nil, autoPlayed: false)

        let result = FeedView.displayItems(from: [undated, dated])

        XCTAssertEqual(result.map(\.episode.id), ["dated", "undated"])
    }
}
