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
        let filename = "cleanup-test-\(UUID().uuidString).mp3"
        let fileURL = directory.appendingPathComponent(filename)
        try Data("audio".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let record = makeRecord(id: "ep1", fileSizeBytes: 5, localFilePath: filename)
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

    // Regression: a localFilePath containing ".." must not let deletion escape the sandboxed
    // downloads directory onto some other file on disk.
    func testDeleteWithPathTraversalLocalFilePathDoesNotEscapeDownloadsDirectory() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let directory = try XCTUnwrap(DownloadManager.downloadsDirectory())
        let outsideFile = directory.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString).txt")
        try Data("do not delete me".utf8).write(to: outsideFile)
        defer { try? FileManager.default.removeItem(at: outsideFile) }

        let record = makeRecord(id: "ep1", fileSizeBytes: 5, localFilePath: "../\(outsideFile.lastPathComponent)")
        context.insert(record)
        try context.save()

        let succeeded = DownloadCleanup.delete([record], from: context)

        XCTAssertTrue(succeeded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideFile.path))
        let descriptor = FetchDescriptor<DownloadedEpisodeRecord>(predicate: #Predicate { $0.id == "ep1" })
        XCTAssertTrue(try context.fetch(descriptor).isEmpty)
    }
}
