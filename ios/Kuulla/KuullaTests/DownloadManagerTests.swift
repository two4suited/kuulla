import SwiftData
import XCTest
@testable import Kuulla

@MainActor
final class DownloadManagerTests: XCTestCase {
    private func makeContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: DownloadedEpisodeRecord.self, configurations: configuration)
    }

    private func makeManager(container: ModelContainer) -> DownloadManager {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let manager = DownloadManager(configuration: config)
        manager.configure(modelContainer: container)
        return manager
    }

    private func waitForStatus(
        _ episodeId: String, notEqualTo pending: DownloadStatus, in context: ModelContext, timeout: TimeInterval = 2
    ) async throws -> DownloadStatus? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let descriptor = FetchDescriptor<DownloadedEpisodeRecord>(predicate: #Predicate { $0.id == episodeId })
            if let record = try context.fetch(descriptor).first, record.status != pending {
                return record.status
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return nil
    }

    private func makeEpisode(id: String = "ep1", audioUrl: String = "https://example.com/ep1.mp3") -> Episode {
        let json = """
        {"id":"\(id)","showId":"show1","title":"Title","audioUrl":"\(audioUrl)"}
        """.data(using: .utf8)!
        return try! JSONDecoder().decode(Episode.self, from: json)
    }

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    func testStartDownloadCreatesDownloadingRecordImmediately() throws {
        let container = try makeContainer()
        let manager = makeManager(container: container)
        MockURLProtocol.stubHandler = { _ in .success(.init(statusCode: 200, data: Data("audio".utf8), headers: [:])) }

        manager.startDownload(episode: makeEpisode())

        let context = ModelContext(container)
        let descriptor = FetchDescriptor<DownloadedEpisodeRecord>(predicate: #Predicate { $0.id == "ep1" })
        let record = try XCTUnwrap(try context.fetch(descriptor).first)
        XCTAssertEqual(record.status, .downloading)
    }

    func testSuccessfulDownloadMarksRecordCompleteWithFileOnDisk() async throws {
        let container = try makeContainer()
        let manager = makeManager(container: container)
        let audioData = Data("fake audio bytes".utf8)
        MockURLProtocol.stubHandler = { _ in .success(.init(statusCode: 200, data: audioData, headers: [:])) }

        manager.startDownload(episode: makeEpisode())

        let context = ModelContext(container)
        let status = try await waitForStatus("ep1", notEqualTo: .downloading, in: context)
        XCTAssertEqual(status, .complete)

        let descriptor = FetchDescriptor<DownloadedEpisodeRecord>(predicate: #Predicate { $0.id == "ep1" })
        let record = try XCTUnwrap(try context.fetch(descriptor).first)
        XCTAssertFalse(record.localFilePath.isEmpty)
        XCTAssertEqual(record.fileSizeBytes, audioData.count)

        let fileURL = try XCTUnwrap(DownloadManager.downloadsDirectory()?.appendingPathComponent(record.localFilePath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        try? FileManager.default.removeItem(at: fileURL)
    }

    func testFailedDownloadMarksRecordFailed() async throws {
        let container = try makeContainer()
        let manager = makeManager(container: container)
        MockURLProtocol.stubHandler = { _ in .failure(URLError(.notConnectedToInternet)) }

        manager.startDownload(episode: makeEpisode())

        let context = ModelContext(container)
        let status = try await waitForStatus("ep1", notEqualTo: .downloading, in: context)
        XCTAssertEqual(status, .failed)
    }

    func testCancelDownloadRemovesRecord() throws {
        let container = try makeContainer()
        let manager = makeManager(container: container)
        MockURLProtocol.stubHandler = { _ in .success(.init(statusCode: 200, data: Data("audio".utf8), headers: [:])) }

        manager.startDownload(episode: makeEpisode())
        manager.cancelDownload(episodeId: "ep1")

        let context = ModelContext(container)
        let descriptor = FetchDescriptor<DownloadedEpisodeRecord>(predicate: #Predicate { $0.id == "ep1" })
        XCTAssertTrue(try context.fetch(descriptor).isEmpty)
        XCTAssertNil(manager.progress["ep1"])
    }

    // Regression: didCompleteWithError for a cancelled task must not wipe out a same-episode
    // retry's tracking/record if the retry started before that stale callback arrives.
    func testCancelThenImmediateRetrySucceeds() async throws {
        let container = try makeContainer()
        let manager = makeManager(container: container)
        MockURLProtocol.stubHandler = { _ in .success(.init(statusCode: 200, data: Data("audio".utf8), headers: [:])) }

        manager.startDownload(episode: makeEpisode())
        manager.cancelDownload(episodeId: "ep1")
        manager.startDownload(episode: makeEpisode())

        let context = ModelContext(container)
        let status = try await waitForStatus("ep1", notEqualTo: .downloading, in: context)
        XCTAssertEqual(status, .complete)
    }

    // Regression: a URL with no extractable file extension (e.g. "https://example.com/episode",
    // no dot in the path) used to produce a filename with a trailing dot and nothing after it.
    func testDownloadFromURLWithoutExtensionFallsBackToDefaultExtension() async throws {
        let container = try makeContainer()
        let manager = makeManager(container: container)
        MockURLProtocol.stubHandler = { _ in .success(.init(statusCode: 200, data: Data("audio".utf8), headers: [:])) }

        manager.startDownload(episode: makeEpisode(audioUrl: "https://example.com/episode"))

        let context = ModelContext(container)
        _ = try await waitForStatus("ep1", notEqualTo: .downloading, in: context)
        let descriptor = FetchDescriptor<DownloadedEpisodeRecord>(predicate: #Predicate { $0.id == "ep1" })
        let record = try XCTUnwrap(try context.fetch(descriptor).first)
        XCTAssertFalse(record.localFilePath.hasSuffix("."))
        // Not asserting a specific fallback extension — URLResponse.suggestedFilename can itself
        // synthesize one from the response's MIME type when the URL's path has none, so the
        // "mp3" fallback in DownloadManager may or may not be what's exercised here. What
        // matters for this regression is only that the result isn't a bare trailing dot.
        XCTAssertFalse((record.localFilePath as NSString).pathExtension.isEmpty)

        if let fileURL = DownloadManager.downloadsDirectory()?.appendingPathComponent(record.localFilePath) {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    // Regression: re-downloading a previously-completed episode used to leave the old
    // localFilePath/fileSizeBytes in place on the reused record while status flipped back to
    // .downloading, so a cancel of the new attempt would delete the *old* file.
    func testReDownloadAfterCompleteClearsPreviousFileState() async throws {
        let container = try makeContainer()
        let manager = makeManager(container: container)
        MockURLProtocol.stubHandler = { _ in .success(.init(statusCode: 200, data: Data("audio".utf8), headers: [:])) }

        manager.startDownload(episode: makeEpisode())
        let context = ModelContext(container)
        _ = try await waitForStatus("ep1", notEqualTo: .downloading, in: context)

        let descriptor = FetchDescriptor<DownloadedEpisodeRecord>(predicate: #Predicate { $0.id == "ep1" })
        let firstRecord = try XCTUnwrap(try context.fetch(descriptor).first)
        let firstFileURL = try XCTUnwrap(DownloadManager.downloadsDirectory()?.appendingPathComponent(firstRecord.localFilePath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstFileURL.path))

        manager.startDownload(episode: makeEpisode())

        // The old file must be gone (or replaced) immediately — upsertRecord clears it
        // synchronously on transitioning back to .downloading, before the new transfer completes.
        let midRecord = try XCTUnwrap(try context.fetch(descriptor).first)
        XCTAssertEqual(midRecord.status, .downloading)
        XCTAssertEqual(midRecord.fileSizeBytes, 0)

        _ = try await waitForStatus("ep1", notEqualTo: .downloading, in: context)
        let finalRecord = try XCTUnwrap(try context.fetch(descriptor).first)
        XCTAssertEqual(finalRecord.status, .complete)

        if let fileURL = DownloadManager.downloadsDirectory()?.appendingPathComponent(finalRecord.localFilePath) {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }
}
