import SwiftData
import XCTest
@testable import Kuulla

final class DownloadedEpisodeRecordTests: XCTestCase {
    private func makeContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: DownloadedEpisodeRecord.self, configurations: configuration)
    }

    func testStatusPersistsAcrossFetch() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let record = DownloadedEpisodeRecord(
            id: "ep1", showId: "show1", localFilePath: "downloads/ep1.mp3",
            fileSizeBytes: 1024, downloadedAt: Date(timeIntervalSince1970: 1_700_000_000), status: .complete)
        context.insert(record)
        try context.save()

        let verifyContext = ModelContext(container)
        let stored = try XCTUnwrap(try verifyContext.fetch(FetchDescriptor<DownloadedEpisodeRecord>()).first)
        XCTAssertEqual(stored.id, "ep1")
        XCTAssertEqual(stored.status, .complete)
        XCTAssertEqual(stored.fileSizeBytes, 1024)
    }

    func testStatusMapFiltersByRequestedIdsOnly() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(DownloadedEpisodeRecord(
            id: "ep1", showId: "show1", localFilePath: "a.mp3", fileSizeBytes: 10, downloadedAt: Date(), status: .complete))
        context.insert(DownloadedEpisodeRecord(
            id: "ep2", showId: "show1", localFilePath: "b.mp3", fileSizeBytes: 20, downloadedAt: Date(), status: .downloading))
        context.insert(DownloadedEpisodeRecord(
            id: "ep3", showId: "show1", localFilePath: "c.mp3", fileSizeBytes: 0, downloadedAt: Date(), status: .failed))
        try context.save()

        let map = DownloadStatus.statusMap(for: ["ep1", "ep3"], in: context)

        XCTAssertEqual(map.count, 2)
        XCTAssertEqual(map["ep1"], .complete)
        XCTAssertEqual(map["ep3"], .failed)
        XCTAssertNil(map["ep2"])
    }

    func testStatusMapForUnknownIdReturnsEmptyDictionary() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let map = DownloadStatus.statusMap(for: ["missing"], in: context)

        XCTAssertTrue(map.isEmpty)
    }

    // MARK: - Local file playback failure fallback (#781)

    func testMarkFailedSetsStatusToFailed() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(DownloadedEpisodeRecord(
            id: "ep1", showId: "show1", localFilePath: "a.mp3", fileSizeBytes: 10, downloadedAt: Date(), status: .complete))
        try context.save()

        DownloadedEpisodeRecord.markFailed(episodeId: "ep1", modelContainer: container)

        let verifyContext = ModelContext(container)
        let stored = try XCTUnwrap(try verifyContext.fetch(FetchDescriptor<DownloadedEpisodeRecord>()).first)
        XCTAssertEqual(stored.status, .failed)
    }

    func testMarkFailedForUnknownEpisodeIsANoOp() throws {
        let container = try makeContainer()

        DownloadedEpisodeRecord.markFailed(episodeId: "missing", modelContainer: container)

        let context = ModelContext(container)
        XCTAssertTrue(try context.fetch(FetchDescriptor<DownloadedEpisodeRecord>()).isEmpty)
    }

    func testWireLocalFileFailureFallbackMarksDownloadFailedAndReplaysWithStreamURL() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(DownloadedEpisodeRecord(
            id: "ep1", showId: "show1", localFilePath: "a.mp3", fileSizeBytes: 10, downloadedAt: Date(), status: .complete))
        try context.save()

        let player = AudioPlayer()
        var replayedURL: URL?
        var replayedPosition: TimeInterval?
        DownloadedEpisodeRecord.wireLocalFileFailureFallback(
            episodeId: "ep1", streamURLString: "https://example.com/audio.mp3", modelContainer: container, on: player
        ) { url, position in
            replayedURL = url
            replayedPosition = position
        }

        let localURL = URL(fileURLWithPath: "/tmp/a.mp3")
        player.onLocalFileFailed?(localURL, 30)

        XCTAssertEqual(replayedURL, URL(string: "https://example.com/audio.mp3"))
        XCTAssertEqual(replayedPosition, 30)
        let verifyContext = ModelContext(container)
        let stored = try XCTUnwrap(try verifyContext.fetch(FetchDescriptor<DownloadedEpisodeRecord>()).first)
        XCTAssertEqual(stored.status, .failed)
    }

    func testWireLocalFileFailureFallbackWithNoModelContainerLeavesCallbackUntouched() {
        let player = AudioPlayer()
        var originalCalled = false
        player.onLocalFileFailed = { _, _ in originalCalled = true }

        DownloadedEpisodeRecord.wireLocalFileFailureFallback(
            episodeId: "ep1", streamURLString: "https://example.com/audio.mp3", modelContainer: nil, on: player
        ) { _, _ in XCTFail("replay should not be reachable when modelContainer is nil") }

        player.onLocalFileFailed?(URL(fileURLWithPath: "/tmp/a.mp3"), 0)
        XCTAssertTrue(originalCalled)
    }
}
