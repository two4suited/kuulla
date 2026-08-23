import XCTest
@testable import Kuulla

final class EpisodeDetailViewTests: XCTestCase {
    private let downloadsDirectory = URL(fileURLWithPath: "/tmp/downloads")

    private func makeRecord(status: DownloadStatus, localFilePath: String = "ep1.mp3") -> DownloadedEpisodeRecord {
        DownloadedEpisodeRecord(
            id: "ep1", showId: "show1", localFilePath: localFilePath, fileSizeBytes: 100,
            downloadedAt: Date(), status: status)
    }

    func testNoDownloadRecordUsesRemoteURL() {
        let url = EpisodeDetailView.resolvedPlaybackURL(
            audioUrlString: "https://example.com/ep1.mp3", downloadRecord: nil, downloadsDirectory: downloadsDirectory)
        XCTAssertEqual(url, URL(string: "https://example.com/ep1.mp3"))
    }

    func testCompletedDownloadUsesLocalFileURL() {
        let record = makeRecord(status: .complete)
        let url = EpisodeDetailView.resolvedPlaybackURL(
            audioUrlString: "https://example.com/ep1.mp3", downloadRecord: record, downloadsDirectory: downloadsDirectory,
            localFileExists: { _ in true })
        XCTAssertEqual(url, downloadsDirectory.appendingPathComponent("ep1.mp3"))
    }

    // Regression: a record can outlive its file (eviction, manual cleanup, a bug elsewhere) —
    // trusting it unconditionally would hand AVPlayer a dead URL with no fallback.
    func testCompletedRecordWithMissingFileFallsBackToRemoteURL() {
        let record = makeRecord(status: .complete)
        let url = EpisodeDetailView.resolvedPlaybackURL(
            audioUrlString: "https://example.com/ep1.mp3", downloadRecord: record, downloadsDirectory: downloadsDirectory,
            localFileExists: { _ in false })
        XCTAssertEqual(url, URL(string: "https://example.com/ep1.mp3"))
    }

    func testInProgressDownloadUsesRemoteURL() {
        let record = makeRecord(status: .downloading)
        let url = EpisodeDetailView.resolvedPlaybackURL(
            audioUrlString: "https://example.com/ep1.mp3", downloadRecord: record, downloadsDirectory: downloadsDirectory)
        XCTAssertEqual(url, URL(string: "https://example.com/ep1.mp3"))
    }

    func testFailedDownloadUsesRemoteURL() {
        let record = makeRecord(status: .failed)
        let url = EpisodeDetailView.resolvedPlaybackURL(
            audioUrlString: "https://example.com/ep1.mp3", downloadRecord: record, downloadsDirectory: downloadsDirectory)
        XCTAssertEqual(url, URL(string: "https://example.com/ep1.mp3"))
    }

    func testCompletedRecordWithEmptyLocalPathFallsBackToRemoteURL() {
        let record = makeRecord(status: .complete, localFilePath: "")
        let url = EpisodeDetailView.resolvedPlaybackURL(
            audioUrlString: "https://example.com/ep1.mp3", downloadRecord: record, downloadsDirectory: downloadsDirectory)
        XCTAssertEqual(url, URL(string: "https://example.com/ep1.mp3"))
    }

    func testCompletedRecordWithNoDownloadsDirectoryFallsBackToRemoteURL() {
        let record = makeRecord(status: .complete)
        let url = EpisodeDetailView.resolvedPlaybackURL(
            audioUrlString: "https://example.com/ep1.mp3", downloadRecord: record, downloadsDirectory: nil)
        XCTAssertEqual(url, URL(string: "https://example.com/ep1.mp3"))
    }
}
