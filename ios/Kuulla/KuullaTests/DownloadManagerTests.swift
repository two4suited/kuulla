import SwiftData
import XCTest
@testable import Kuulla

// Captures the callback DownloadManager registers so tests can simulate Wi-Fi/cellular
// transitions synchronously instead of depending on the device's real network state.
final class MockPathObserver: NetworkPathObserving {
    private(set) var onUpdate: ((Bool) -> Void)?

    func startObserving(onUpdate: @escaping (Bool) -> Void) {
        self.onUpdate = onUpdate
    }

    // Deterministically waits for DownloadManager to have applied this update — its registered
    // closure dispatches handlePathUpdate onto the main queue via DispatchQueue.main.async, so
    // enqueueing this continuation's resume the same way *after* calling onUpdate guarantees it
    // runs after handlePathUpdate has (GCD's main queue is FIFO), without a fixed sleep-and-hope.
    func simulate(isOnWifi: Bool) async {
        await withCheckedContinuation { continuation in
            onUpdate?(isOnWifi)
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}

@MainActor
final class DownloadManagerTests: XCTestCase {
    private func makeContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: DownloadedEpisodeRecord.self, configurations: configuration)
    }

    // DownloadManager now defaults to isOnWifi == false until told otherwise (#180's
    // pessimistic-until-known default — see DownloadManager.swift), which combined with
    // LocalSettings.wifiOnlyDownloads' own true-when-unset default would queue every download in
    // tests that don't care about network state at all. Establishing "on Wi-Fi" here by default
    // keeps every pre-existing test's behavior unchanged; tests that specifically exercise Wi-Fi
    // gating pass their own MockPathObserver and simulate off-Wi-Fi explicitly afterward.
    private func makeManager(container: ModelContainer, pathObserver: NetworkPathObserving = MockPathObserver()) async -> DownloadManager {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let manager = DownloadManager(configuration: config, pathObserver: pathObserver)
        manager.configure(modelContainer: container)
        if let mockPathObserver = pathObserver as? MockPathObserver {
            await mockPathObserver.simulate(isOnWifi: true)
        }
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

    func testStartDownloadCreatesDownloadingRecordImmediately() async throws {
        let container = try makeContainer()
        let manager = await makeManager(container: container)
        MockURLProtocol.stubHandler = { _ in .success(.init(statusCode: 200, data: Data("audio".utf8), headers: [:])) }

        manager.startDownload(episode: makeEpisode())

        let context = ModelContext(container)
        let descriptor = FetchDescriptor<DownloadedEpisodeRecord>(predicate: #Predicate { $0.id == "ep1" })
        let record = try XCTUnwrap(try context.fetch(descriptor).first)
        XCTAssertEqual(record.status, .downloading)
    }

    func testSuccessfulDownloadMarksRecordCompleteWithFileOnDisk() async throws {
        let container = try makeContainer()
        let manager = await makeManager(container: container)
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
        let manager = await makeManager(container: container)
        MockURLProtocol.stubHandler = { _ in .failure(URLError(.notConnectedToInternet)) }

        manager.startDownload(episode: makeEpisode())

        let context = ModelContext(container)
        let status = try await waitForStatus("ep1", notEqualTo: .downloading, in: context)
        XCTAssertEqual(status, .failed)
    }

    func testCancelDownloadRemovesRecord() async throws {
        let container = try makeContainer()
        let manager = await makeManager(container: container)
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
        let manager = await makeManager(container: container)
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
        let manager = await makeManager(container: container)
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
        let manager = await makeManager(container: container)
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

    // MARK: - Wi-Fi-only downloads (#180)

    private func withWifiOnlyDownloads(_ enabled: Bool, _ body: () async throws -> Void) async rethrows {
        let previous = UserDefaults.standard.object(forKey: LocalSettings.wifiOnlyDownloadsKey)
        UserDefaults.standard.set(enabled, forKey: LocalSettings.wifiOnlyDownloadsKey)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: LocalSettings.wifiOnlyDownloadsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: LocalSettings.wifiOnlyDownloadsKey)
            }
        }
        try await body()
    }

    func testStartDownloadQueuesWhenWifiOnlyEnabledAndOffWifi() async throws {
        try await withWifiOnlyDownloads(true) {
            let container = try makeContainer()
            let pathObserver = MockPathObserver()
            let manager = await makeManager(container: container, pathObserver: pathObserver)
            await pathObserver.simulate(isOnWifi: false)

            MockURLProtocol.stubHandler = { _ in .success(.init(statusCode: 200, data: Data("audio".utf8), headers: [:])) }
            manager.startDownload(episode: makeEpisode())

            // Queued, not started: no live progress entry, and the record shows .downloading
            // without ever having reached .complete.
            XCTAssertNil(manager.progress["ep1"])
            let context = ModelContext(container)
            let descriptor = FetchDescriptor<DownloadedEpisodeRecord>(predicate: #Predicate { $0.id == "ep1" })
            let record = try XCTUnwrap(try context.fetch(descriptor).first)
            XCTAssertEqual(record.status, .downloading)

            // Wi-Fi returns — the queued download starts automatically.
            await pathObserver.simulate(isOnWifi: true)
            let status = try await waitForStatus("ep1", notEqualTo: .downloading, in: context)
            XCTAssertEqual(status, .complete)

            if let record = try context.fetch(descriptor).first, !record.localFilePath.isEmpty,
               let fileURL = DownloadManager.downloadsDirectory()?.appendingPathComponent(record.localFilePath) {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
    }

    func testStartDownloadProceedsImmediatelyWhenWifiOnlyDisabledEvenOffWifi() async throws {
        try await withWifiOnlyDownloads(false) {
            let container = try makeContainer()
            let pathObserver = MockPathObserver()
            let manager = await makeManager(container: container, pathObserver: pathObserver)
            await pathObserver.simulate(isOnWifi: false)

            MockURLProtocol.stubHandler = { _ in .success(.init(statusCode: 200, data: Data("audio".utf8), headers: [:])) }
            manager.startDownload(episode: makeEpisode())

            let context = ModelContext(container)
            let status = try await waitForStatus("ep1", notEqualTo: .downloading, in: context)
            XCTAssertEqual(status, .complete)

            let descriptor = FetchDescriptor<DownloadedEpisodeRecord>(predicate: #Predicate { $0.id == "ep1" })
            if let record = try context.fetch(descriptor).first, !record.localFilePath.isEmpty,
               let fileURL = DownloadManager.downloadsDirectory()?.appendingPathComponent(record.localFilePath) {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
    }

    func testCancelDownloadRemovesQueuedEpisode() async throws {
        try await withWifiOnlyDownloads(true) {
            let container = try makeContainer()
            let pathObserver = MockPathObserver()
            let manager = await makeManager(container: container, pathObserver: pathObserver)
            await pathObserver.simulate(isOnWifi: false)

            MockURLProtocol.stubHandler = { _ in .success(.init(statusCode: 200, data: Data("audio".utf8), headers: [:])) }
            manager.startDownload(episode: makeEpisode())
            manager.cancelDownload(episodeId: "ep1")

            let context = ModelContext(container)
            let descriptor = FetchDescriptor<DownloadedEpisodeRecord>(predicate: #Predicate { $0.id == "ep1" })
            XCTAssertTrue(try context.fetch(descriptor).isEmpty)

            // Wi-Fi returning afterward must not resurrect the cancelled, no-longer-queued download.
            await pathObserver.simulate(isOnWifi: true)
            XCTAssertTrue(try context.fetch(descriptor).isEmpty)
        }
    }

    // MARK: recordsToEvict (#689)

    func testRecordsToEvictKeepsNewestByDownloadedAtAndEvictsOlder() {
        let old = DownloadedEpisodeRecord(
            id: "old", showId: "show1", localFilePath: "", fileSizeBytes: 0,
            downloadedAt: Date(timeIntervalSince1970: 1), status: .complete)
        let mid = DownloadedEpisodeRecord(
            id: "mid", showId: "show1", localFilePath: "", fileSizeBytes: 0,
            downloadedAt: Date(timeIntervalSince1970: 2), status: .complete)
        let new = DownloadedEpisodeRecord(
            id: "new", showId: "show1", localFilePath: "", fileSizeBytes: 0,
            downloadedAt: Date(timeIntervalSince1970: 3), status: .complete)

        let evicted = DownloadManager.recordsToEvict(current: [old, mid, new], limit: 2)

        XCTAssertEqual(evicted.map(\.id), ["old"])
    }

    func testRecordsToEvictReturnsEmptyWhenAtOrUnderLimit() {
        let record = DownloadedEpisodeRecord(
            id: "ep1", showId: "show1", localFilePath: "", fileSizeBytes: 0, downloadedAt: Date(), status: .complete)

        XCTAssertTrue(DownloadManager.recordsToEvict(current: [record], limit: 1).isEmpty)
    }

    func testRecordsToEvictReturnsEmptyWhenLimitIsZero() {
        let record = DownloadedEpisodeRecord(
            id: "ep1", showId: "show1", localFilePath: "", fileSizeBytes: 0, downloadedAt: Date(), status: .complete)

        XCTAssertTrue(DownloadManager.recordsToEvict(current: [record], limit: 0).isEmpty)
    }

    // MARK: enforceEpisodeLimit (#689)

    func testEnforceEpisodeLimitDeletesOldestCompletedDownloadBeyondLimit() async throws {
        let container = try makeContainer()
        let manager = await makeManager(container: container)
        let context = ModelContext(container)
        let old = DownloadedEpisodeRecord(
            id: "old", showId: "show1", localFilePath: "", fileSizeBytes: 0,
            downloadedAt: Date(timeIntervalSince1970: 1), status: .complete)
        let new = DownloadedEpisodeRecord(
            id: "new", showId: "show1", localFilePath: "", fileSizeBytes: 0,
            downloadedAt: Date(timeIntervalSince1970: 2), status: .complete)
        context.insert(old)
        context.insert(new)
        try context.save()

        manager.enforceEpisodeLimit(showId: "show1", limit: 1, in: context)

        let remaining = try context.fetch(FetchDescriptor<DownloadedEpisodeRecord>())
        XCTAssertEqual(remaining.map(\.id), ["new"])
    }

    func testEnforceEpisodeLimitDoesNothingWhenLimitIsZero() async throws {
        let container = try makeContainer()
        let manager = await makeManager(container: container)
        let context = ModelContext(container)
        let record = DownloadedEpisodeRecord(
            id: "ep1", showId: "show1", localFilePath: "", fileSizeBytes: 0, downloadedAt: Date(), status: .complete)
        context.insert(record)
        try context.save()

        manager.enforceEpisodeLimit(showId: "show1", limit: 0, in: context)

        XCTAssertEqual(try context.fetch(FetchDescriptor<DownloadedEpisodeRecord>()).count, 1)
    }

    func testEnforceEpisodeLimitIgnoresOtherShows() async throws {
        let container = try makeContainer()
        let manager = await makeManager(container: container)
        let context = ModelContext(container)
        let record = DownloadedEpisodeRecord(
            id: "ep1", showId: "other-show", localFilePath: "", fileSizeBytes: 0, downloadedAt: Date(), status: .complete)
        context.insert(record)
        try context.save()

        manager.enforceEpisodeLimit(showId: "show1", limit: 1, in: context)

        XCTAssertEqual(try context.fetch(FetchDescriptor<DownloadedEpisodeRecord>()).count, 1)
    }
}
