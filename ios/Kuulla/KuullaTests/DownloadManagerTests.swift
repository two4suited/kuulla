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

    // A 200 whose body is an HTML page (expired signed URL, geo-block, sign-in interstitial) is a
    // failed download, not a completed one — the page must not be saved as <episodeId>.mp3 to
    // then fail at play time with no explanation.
    func testHtmlResponseMarksDownloadFailedInsteadOfSavingIt() async throws {
        let container = try makeContainer()
        let manager = await makeManager(container: container)
        MockURLProtocol.stubHandler = { _ in
            .success(.init(
                statusCode: 200,
                data: Data("<!DOCTYPE html><html><body>This link has expired.</body></html>".utf8),
                headers: ["Content-Type": "text/html; charset=utf-8"]))
        }

        manager.startDownload(episode: makeEpisode())

        let context = ModelContext(container)
        let status = try await waitForStatus("ep1", notEqualTo: .downloading, in: context)
        XCTAssertEqual(status, .failed)
        let descriptor = FetchDescriptor<DownloadedEpisodeRecord>(predicate: #Predicate { $0.id == "ep1" })
        let record = try XCTUnwrap(try context.fetch(descriptor).first)
        XCTAssertTrue(record.localFilePath.isEmpty)
        XCTAssertNil(manager.progress["ep1"])
    }

    // A download task also "completes" for a 4xx/5xx — the error body is delivered as the file.
    func testNonSuccessStatusMarksDownloadFailed() async throws {
        let container = try makeContainer()
        let manager = await makeManager(container: container)
        MockURLProtocol.stubHandler = { _ in
            .success(.init(
                statusCode: 403,
                data: Data(#"{"error":"signed URL expired"}"#.utf8),
                headers: ["Content-Type": "application/json"]))
        }

        manager.startDownload(episode: makeEpisode())

        let context = ModelContext(container)
        let status = try await waitForStatus("ep1", notEqualTo: .downloading, in: context)
        XCTAssertEqual(status, .failed)
        XCTAssertNil(manager.progress["ep1"])
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

// The extension a finished download is saved under decides whether AVFoundation can open it at
// all (it identifies local files by extension) — pure-function coverage of the trust order:
// declared audio Content-Type, then a known audio URL extension, then magic bytes, then "mp3".
final class DownloadFileTypeDetectionTests: XCTestCase {
    private let id3Header = Data([0x49, 0x44, 0x33, 0x04, 0x00, 0x00, 0x00, 0x00])
    private let mp4Header = Data([0x00, 0x00, 0x00, 0x20, 0x66, 0x74, 0x79, 0x70, 0x4D, 0x34, 0x41, 0x20])

    // The bytes are the container; a host's blanket "audio/mpeg" on an M4A enclosure is the
    // mislabelling the whole change exists to survive.
    func testContainerSignatureWinsOverDeclaredMimeType() {
        XCTAssertEqual(
            DownloadManager.audioFileExtension(mimeType: "audio/mpeg", suggestedFilename: "episode.mp3", headerBytes: mp4Header),
            "m4a")
        XCTAssertEqual(
            DownloadManager.audioFileExtension(mimeType: "audio/mp4", suggestedFilename: "episode.m4a", headerBytes: id3Header),
            "mp3")
    }

    // Unlike a real signature, the two-byte MPEG frame sync is too weak to override a declared
    // type or a known URL extension.
    func testFrameSyncRanksBelowDeclaredTypeAndUrlExtension() {
        let bareSync = Data([0xFF, 0xFB, 0x90, 0x64])
        XCTAssertEqual(
            DownloadManager.audioFileExtension(mimeType: "audio/mp4", suggestedFilename: nil, headerBytes: bareSync), "m4a")
        XCTAssertEqual(
            DownloadManager.audioFileExtension(mimeType: nil, suggestedFilename: "episode.m4a", headerBytes: bareSync), "m4a")
        XCTAssertEqual(
            DownloadManager.audioFileExtension(mimeType: nil, suggestedFilename: "download", headerBytes: bareSync), "mp3")
    }

    func testDeclaredMimeTypeWinsOverMisleadingUrlExtension() {
        XCTAssertEqual(
            DownloadManager.audioFileExtension(mimeType: "audio/mp4", suggestedFilename: "episode.mp3", headerBytes: Data()),
            "m4a")
        XCTAssertEqual(
            DownloadManager.audioFileExtension(
                mimeType: "audio/mpeg; charset=binary", suggestedFilename: "episode.m4a", headerBytes: Data()),
            "mp3")
    }

    func testKnownUrlExtensionIsUsedWhenMimeTypeIsUnhelpful() {
        XCTAssertEqual(
            DownloadManager.audioFileExtension(
                mimeType: "application/octet-stream", suggestedFilename: "Episode 12.M4A", headerBytes: Data()),
            "m4a")
        XCTAssertEqual(
            DownloadManager.audioFileExtension(mimeType: nil, suggestedFilename: "episode.mp3", headerBytes: Data()),
            "mp3")
    }

    // A script-style download endpoint's extension must never be copied onto the file.
    func testNonAudioUrlExtensionFallsThroughToMagicBytes() {
        XCTAssertEqual(
            DownloadManager.audioFileExtension(mimeType: nil, suggestedFilename: "play.php", headerBytes: mp4Header),
            "m4a")
        XCTAssertEqual(
            DownloadManager.audioFileExtension(
                mimeType: "application/octet-stream", suggestedFilename: "download", headerBytes: id3Header),
            "mp3")
    }

    func testMagicBytesRecognizeCommonContainers() {
        XCTAssertEqual(DownloadManager.sniffedAudioExtension(headerBytes: id3Header), "mp3")
        XCTAssertEqual(DownloadManager.sniffedAudioExtension(headerBytes: mp4Header), "m4a")
        XCTAssertEqual(DownloadManager.sniffedAudioExtension(headerBytes: Data("RIFF....WAVE".utf8)), "wav")
        XCTAssertEqual(DownloadManager.sniffedAudioExtension(headerBytes: Data("fLaC....".utf8)), "flac")
        XCTAssertEqual(DownloadManager.sniffedAudioExtension(headerBytes: Data("OggS....".utf8)), "ogg")
        // Bare MPEG frame sync (no ID3 tag) vs. an ADTS AAC frame sync.
        XCTAssertEqual(DownloadManager.sniffedAudioExtension(headerBytes: Data([0xFF, 0xFB, 0x90, 0x64])), "mp3")
        XCTAssertEqual(DownloadManager.sniffedAudioExtension(headerBytes: Data([0xFF, 0xF1, 0x50, 0x80])), "aac")
        XCTAssertNil(DownloadManager.sniffedAudioExtension(headerBytes: Data("<html>".utf8)))
        XCTAssertNil(DownloadManager.sniffedAudioExtension(headerBytes: Data()))
    }

    func testUnrecognizedPayloadDefaultsToMp3() {
        XCTAssertEqual(
            DownloadManager.audioFileExtension(mimeType: nil, suggestedFilename: "download", headerBytes: Data("audio".utf8)),
            "mp3")
    }

    func testHtmlPayloadIsNotAudio() {
        XCTAssertFalse(DownloadManager.looksLikeAudioContent(mimeType: "text/html", headerBytes: Data("<html>".utf8), byteCount: 2_000))
        // Markup with a lying (or absent) Content-Type is still a web page, whatever its size.
        XCTAssertFalse(DownloadManager.looksLikeAudioContent(
            mimeType: "audio/mpeg", headerBytes: Data("\u{FEFF}<!DOCTYPE html>".utf8), byteCount: 50_000_000))
        XCTAssertFalse(DownloadManager.looksLikeAudioContent(mimeType: nil, headerBytes: Data("  <html lang=\"en\">".utf8), byteCount: 2_000))
        // Declared text/html with no visible markup in the leading bytes: only an error-page-sized
        // body is refused.
        XCTAssertFalse(DownloadManager.looksLikeAudioContent(mimeType: "text/html", headerBytes: Data(count: 512), byteCount: 4_096))
    }

    func testAudioPayloadIsAudioEvenWithHtmlContentType() {
        XCTAssertTrue(DownloadManager.looksLikeAudioContent(mimeType: "text/html", headerBytes: id3Header, byteCount: 100))
        XCTAssertTrue(DownloadManager.looksLikeAudioContent(mimeType: "audio/mpeg", headerBytes: Data(), byteCount: 0))
        XCTAssertTrue(DownloadManager.looksLikeAudioContent(mimeType: nil, headerBytes: Data("audio".utf8), byteCount: 5))
        // An MP3 with junk before its first frame, behind a host that labels everything text/html
        // (PHP's default): episode-sized, so it's kept rather than refused forever.
        XCTAssertTrue(DownloadManager.looksLikeAudioContent(mimeType: "text/html", headerBytes: Data(count: 512), byteCount: 40_000_000))
    }

    func testPayloadAcceptanceRequiresSuccessStatus() {
        XCTAssertFalse(DownloadManager.isAcceptablePayload(statusCode: 404, mimeType: "audio/mpeg", headerBytes: id3Header, byteCount: 100))
        XCTAssertTrue(DownloadManager.isAcceptablePayload(statusCode: 200, mimeType: "audio/mpeg", headerBytes: id3Header, byteCount: 100))
        XCTAssertTrue(DownloadManager.isAcceptablePayload(statusCode: nil, mimeType: nil, headerBytes: Data("audio".utf8), byteCount: 5))
    }
}
