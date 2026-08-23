import SwiftData
import XCTest
@testable import Kuulla

final class DownloadCleanupTests: XCTestCase {
    private func makeContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: DownloadedEpisodeRecord.self, configurations: configuration)
    }

    private func makeRecord(id: String, fileSizeBytes: Int, localFilePath: String) -> DownloadedEpisodeRecord {
        DownloadedEpisodeRecord(
            id: id, showId: "show1", localFilePath: localFilePath, fileSizeBytes: fileSizeBytes,
            downloadedAt: Date(), status: .complete)
    }

    func testTotalBytesSumsAcrossRecords() {
        let records = [
            makeRecord(id: "ep1", fileSizeBytes: 1000, localFilePath: "ep1.mp3"),
            makeRecord(id: "ep2", fileSizeBytes: 2500, localFilePath: "ep2.mp3"),
        ]
        XCTAssertEqual(DownloadCleanup.totalBytes(for: records), 3500)
    }

    func testTotalBytesForEmptyListIsZero() {
        XCTAssertEqual(DownloadCleanup.totalBytes(for: []), 0)
    }

    func testDeleteRemovesRecordsFromContextAndFilesFromDisk() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let directory = try XCTUnwrap(DownloadManager.downloadsDirectory())
        let fileURL = directory.appendingPathComponent("cleanup-test-ep1.mp3")
        try Data("audio".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let record = makeRecord(id: "ep1", fileSizeBytes: 5, localFilePath: "cleanup-test-ep1.mp3")
        context.insert(record)
        try context.save()

        let succeeded = DownloadCleanup.delete([record], from: context)

        XCTAssertTrue(succeeded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        let descriptor = FetchDescriptor<DownloadedEpisodeRecord>(predicate: #Predicate { $0.id == "ep1" })
        XCTAssertTrue(try context.fetch(descriptor).isEmpty)
    }

    func testDeleteWithEmptyLocalFilePathOnlyRemovesRecord() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let record = makeRecord(id: "ep1", fileSizeBytes: 0, localFilePath: "")
        context.insert(record)
        try context.save()

        let succeeded = DownloadCleanup.delete([record], from: context)

        XCTAssertTrue(succeeded)
        let descriptor = FetchDescriptor<DownloadedEpisodeRecord>(predicate: #Predicate { $0.id == "ep1" })
        XCTAssertTrue(try context.fetch(descriptor).isEmpty)
    }
}
