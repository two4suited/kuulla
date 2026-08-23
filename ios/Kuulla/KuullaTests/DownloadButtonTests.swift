import XCTest
@testable import Kuulla

final class DownloadButtonTests: XCTestCase {
    func testLiveProgressOverridesPersistedStatusToDownloading() {
        let status = DownloadButton.effectiveStatus(liveProgress: 0.4, persistedStatus: .complete)
        XCTAssertEqual(status, .downloading)
    }

    func testLiveProgressAtZeroStillCountsAsDownloading() {
        // A just-started download reports 0 progress — must not be mistaken for "no progress
        // tracked" (nil), which would fall through to the stale persisted status instead.
        let status = DownloadButton.effectiveStatus(liveProgress: 0, persistedStatus: nil)
        XCTAssertEqual(status, .downloading)
    }

    func testNoLiveProgressFallsBackToPersistedComplete() {
        let status = DownloadButton.effectiveStatus(liveProgress: nil, persistedStatus: .complete)
        XCTAssertEqual(status, .complete)
    }

    func testNoLiveProgressFallsBackToPersistedFailed() {
        let status = DownloadButton.effectiveStatus(liveProgress: nil, persistedStatus: .failed)
        XCTAssertEqual(status, .failed)
    }

    func testNoLiveProgressAndNoPersistedStatusIsNil() {
        let status = DownloadButton.effectiveStatus(liveProgress: nil, persistedStatus: nil)
        XCTAssertNil(status)
    }
}
