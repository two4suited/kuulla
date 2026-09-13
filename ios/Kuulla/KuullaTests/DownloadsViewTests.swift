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

    // Regression (#517): DownloadsView lists rows by fetching every DownloadedEpisodeRecord
    // sorted by downloadedAt desc and filtering to .complete in Swift (it used to fetch only
    // .complete in a one-shot #Predicate that never re-ran when a download finished on screen).
    // This locks in that a record flipping .downloading -> .complete on a *separate*
    // ModelContext — exactly what DownloadManager's background-session callback does — becomes
    // visible to a fresh fetch on another context of the same container, newest first.
    func testCompletedDownloadBecomesVisibleAndSortsNewestFirst() throws {
        let container = try makeContainer()
        let writeContext = ModelContext(container)

        let older = makeRecord(id: "old", fileSizeBytes: 10, localFilePath: "old.mp3")
        older.downloadedAt = Date(timeIntervalSince1970: 1_000)
        let pending = makeRecord(id: "new", fileSizeBytes: 0, localFilePath: "")
        pending.status = .downloading
        pending.downloadedAt = Date(timeIntervalSince1970: 2_000)
        writeContext.insert(older)
        writeContext.insert(pending)
        try writeContext.save()

        func completeRows(in context: ModelContext) throws -> [DownloadedEpisodeRecord] {
            let descriptor = FetchDescriptor<DownloadedEpisodeRecord>(
                sortBy: [SortDescriptor(\.downloadedAt, order: .reverse)])
            return try context.fetch(descriptor).filter { $0.status == .complete }
        }

        XCTAssertEqual(try completeRows(in: ModelContext(container)).map(\.id), ["old"])

        // Simulate the download finishing on the writer's context.
        pending.status = .complete
        pending.fileSizeBytes = 5_000
        try writeContext.save()

        let visible = try completeRows(in: ModelContext(container))
        XCTAssertEqual(visible.map(\.id), ["new", "old"])
        XCTAssertEqual(DownloadCleanup.totalBytes(for: visible), 5_010)
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

    // MARK: - deleteIfAutoDeleteEligible (#532)

    // Regression: ShowDetailView's swipe-to-mark-played used to write completed state directly
    // without ever consulting the auto-delete-after-played rule, so downloads survived a manual
    // mark-played. Both ShowDetailView and EpisodeDetailView now route through this shared check.
    func testDeleteIfAutoDeleteEligibleRemovesCompletedDownloadWhenRuleIsAfterPlayed() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let record = makeRecord(id: "ep1", fileSizeBytes: 5, localFilePath: "")
        context.insert(record)
        try context.save()

        let deleted = DownloadCleanup.deleteIfAutoDeleteEligible(
            episodeId: "ep1", completed: true, autoDeleteRule: .afterPlayed, in: context)

        XCTAssertTrue(deleted)
        let descriptor = FetchDescriptor<DownloadedEpisodeRecord>(predicate: #Predicate { $0.id == "ep1" })
        XCTAssertTrue(try context.fetch(descriptor).isEmpty)
    }

    func testDeleteIfAutoDeleteEligibleLeavesDownloadWhenRuleIsNever() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let record = makeRecord(id: "ep1", fileSizeBytes: 5, localFilePath: "")
        context.insert(record)
        try context.save()

        let deleted = DownloadCleanup.deleteIfAutoDeleteEligible(
            episodeId: "ep1", completed: true, autoDeleteRule: .never, in: context)

        XCTAssertFalse(deleted)
        let descriptor = FetchDescriptor<DownloadedEpisodeRecord>(predicate: #Predicate { $0.id == "ep1" })
        XCTAssertFalse(try context.fetch(descriptor).isEmpty)
    }

    func testDeleteIfAutoDeleteEligibleLeavesInProgressDownloadAlone() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let record = makeRecord(id: "ep1", fileSizeBytes: 5, localFilePath: "")
        record.status = .downloading
        context.insert(record)
        try context.save()

        let deleted = DownloadCleanup.deleteIfAutoDeleteEligible(
            episodeId: "ep1", completed: true, autoDeleteRule: .afterPlayed, in: context)

        XCTAssertFalse(deleted)
        let descriptor = FetchDescriptor<DownloadedEpisodeRecord>(predicate: #Predicate { $0.id == "ep1" })
        XCTAssertFalse(try context.fetch(descriptor).isEmpty)
    }

    func testDeleteIfAutoDeleteEligibleIsNoOpWhenNoDownloadExists() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let deleted = DownloadCleanup.deleteIfAutoDeleteEligible(
            episodeId: "no-such-episode", completed: true, autoDeleteRule: .afterPlayed, in: context)

        XCTAssertFalse(deleted)
    }

    // MARK: - deleteAllEligible(forShowId:) (#532)

    // Regression: ShowDetailView's "mark all played" only looped over its @State `episodes`
    // array, which holds whatever page is currently paginated into memory — a downloaded episode
    // on a not-yet-loaded page was never cleaned up even though the server marks the whole back
    // catalogue played. The show-scoped fetch here is independent of any in-memory episode list.
    func testDeleteAllEligibleRemovesEveryCompletedDownloadForShowRegardlessOfLoadedPages() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let record1 = makeRecord(id: "ep1", fileSizeBytes: 5, localFilePath: "")
        let record2 = makeRecord(id: "ep2", fileSizeBytes: 5, localFilePath: "")
        context.insert(record1)
        context.insert(record2)
        try context.save()

        let deletedIds = DownloadCleanup.deleteAllEligible(forShowId: "show1", autoDeleteRule: .afterPlayed, in: context)

        XCTAssertEqual(Set(deletedIds), ["ep1", "ep2"])
        let descriptor = FetchDescriptor<DownloadedEpisodeRecord>()
        XCTAssertTrue(try context.fetch(descriptor).isEmpty)
    }

    func testDeleteAllEligibleIgnoresOtherShows() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let record = DownloadedEpisodeRecord(
            id: "ep1", showId: "other-show", localFilePath: "", fileSizeBytes: 5,
            downloadedAt: Date(), status: .complete)
        context.insert(record)
        try context.save()

        let deletedIds = DownloadCleanup.deleteAllEligible(forShowId: "show1", autoDeleteRule: .afterPlayed, in: context)

        XCTAssertTrue(deletedIds.isEmpty)
        let descriptor = FetchDescriptor<DownloadedEpisodeRecord>(predicate: #Predicate { $0.id == "ep1" })
        XCTAssertFalse(try context.fetch(descriptor).isEmpty)
    }

    func testDeleteAllEligibleDoesNothingWhenRuleIsNever() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let record = makeRecord(id: "ep1", fileSizeBytes: 5, localFilePath: "")
        context.insert(record)
        try context.save()

        let deletedIds = DownloadCleanup.deleteAllEligible(forShowId: "show1", autoDeleteRule: .never, in: context)

        XCTAssertTrue(deletedIds.isEmpty)
        let descriptor = FetchDescriptor<DownloadedEpisodeRecord>(predicate: #Predicate { $0.id == "ep1" })
        XCTAssertFalse(try context.fetch(descriptor).isEmpty)
    }

    func testDeleteAllEligibleSkipsInProgressDownloads() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let record = makeRecord(id: "ep1", fileSizeBytes: 5, localFilePath: "")
        record.status = .downloading
        context.insert(record)
        try context.save()

        let deletedIds = DownloadCleanup.deleteAllEligible(forShowId: "show1", autoDeleteRule: .afterPlayed, in: context)

        XCTAssertTrue(deletedIds.isEmpty)
        let descriptor = FetchDescriptor<DownloadedEpisodeRecord>(predicate: #Predicate { $0.id == "ep1" })
        XCTAssertFalse(try context.fetch(descriptor).isEmpty)
    }

    // MARK: - playedRecords (#690)

    func testPlayedRecordsIncludesPlayedAndAutoPlayedButNotOthers() {
        let played = makeRecord(id: "played", fileSizeBytes: 1, localFilePath: "")
        let autoPlayed = makeRecord(id: "auto-played", fileSizeBytes: 1, localFilePath: "")
        let inProgress = makeRecord(id: "in-progress", fileSizeBytes: 1, localFilePath: "")
        let new = makeRecord(id: "new", fileSizeBytes: 1, localFilePath: "")
        let statuses: [String: EpisodeStatus] = [
            "played": .played, "auto-played": .autoPlayed, "in-progress": .inProgress,
        ]

        let result = DownloadCleanup.playedRecords([played, autoPlayed, inProgress, new], statuses: statuses)

        XCTAssertEqual(Set(result.map(\.id)), ["played", "auto-played"])
    }

    func testPlayedRecordsTreatsMissingStatusAsNotPlayed() {
        let record = makeRecord(id: "ep1", fileSizeBytes: 1, localFilePath: "")

        let result = DownloadCleanup.playedRecords([record], statuses: [:])

        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - recordsOlderThan (#690)

    func testRecordsOlderThanExcludesRecordsNewerThanCutoff() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let old = makeRecord(id: "old", fileSizeBytes: 1, localFilePath: "")
        old.downloadedAt = Calendar.current.date(byAdding: .day, value: -10, to: now)!
        let recent = makeRecord(id: "recent", fileSizeBytes: 1, localFilePath: "")
        recent.downloadedAt = Calendar.current.date(byAdding: .day, value: -1, to: now)!

        let result = DownloadCleanup.recordsOlderThan(days: 7, in: [old, recent], now: now)

        XCTAssertEqual(result.map(\.id), ["old"])
    }

    func testRecordsOlderThanIsEmptyWhenNothingIsOldEnough() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let recent = makeRecord(id: "recent", fileSizeBytes: 1, localFilePath: "")
        recent.downloadedAt = now

        let result = DownloadCleanup.recordsOlderThan(days: 30, in: [recent], now: now)

        XCTAssertTrue(result.isEmpty)
    }
}
