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
}
