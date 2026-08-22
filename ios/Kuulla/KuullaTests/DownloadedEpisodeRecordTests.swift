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
}
