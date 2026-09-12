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

    // MARK: - Auto-delete after playback (#179)

    func testAutoDeleteFiresWhenCompletedAndRuleIsAfterPlayed() {
        XCTAssertTrue(DownloadCleanup.shouldAutoDelete(completed: true, autoDeleteRule: .afterPlayed))
    }

    func testAutoDeleteDoesNotFireWhenNotCompleted() {
        XCTAssertFalse(DownloadCleanup.shouldAutoDelete(completed: false, autoDeleteRule: .afterPlayed))
    }

    func testAutoDeleteDoesNotFireWhenRuleIsNever() {
        XCTAssertFalse(DownloadCleanup.shouldAutoDelete(completed: true, autoDeleteRule: .never))
    }

    func testAutoDeleteDoesNotFireWhenRuleIsAfterDays() {
        // AfterDays is time-based, independent of played state — this hook only implements the
        // AfterPlayed case; a scheduled AfterDays sweep is separate, unimplemented follow-up work.
        XCTAssertFalse(DownloadCleanup.shouldAutoDelete(completed: true, autoDeleteRule: .afterDays))
    }

    // MARK: - Auto-delete rule resolution (show override vs. global default)

    private func makeUserSettings(autoDeleteRule: AutoDeleteRule) -> UserSettings {
        UserSettings(
            userId: "u1", unlistenedEpisodeCount: .ten, version: 1, autoArchiveRule: .never,
            autoDeleteRule: autoDeleteRule)
    }

    private func makeShowSettings(autoDeleteRule: AutoDeleteRule?) -> ShowSettings {
        ShowSettings(
            id: "show:u1:s1", userId: "u1", showId: "s1", unlistenedEpisodeCount: nil,
            version: 1, autoArchiveRule: nil, autoDeleteRule: autoDeleteRule)
    }

    func testResolvedAutoDeleteRulePrefersShowOverrideOverGlobalDefault() {
        let show = makeShowSettings(autoDeleteRule: .afterPlayed)
        let user = makeUserSettings(autoDeleteRule: .never)
        XCTAssertEqual(EpisodeDetailView.resolvedAutoDeleteRule(show: show, user: user), .afterPlayed)
    }

    func testResolvedAutoDeleteRuleFallsBackToGlobalDefaultWhenShowHasNoOverride() {
        let show = makeShowSettings(autoDeleteRule: nil)
        let user = makeUserSettings(autoDeleteRule: .afterPlayed)
        XCTAssertEqual(EpisodeDetailView.resolvedAutoDeleteRule(show: show, user: user), .afterPlayed)
    }

    func testResolvedAutoDeleteRuleFallsBackToNeverWhenNeitherSettingIsAvailable() {
        XCTAssertEqual(EpisodeDetailView.resolvedAutoDeleteRule(show: nil, user: nil), .never)
    }
}
