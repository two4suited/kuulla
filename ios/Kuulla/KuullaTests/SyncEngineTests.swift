import SwiftData
import XCTest
@testable import Kuulla

final class SyncEngineTests: MockedApiTestCase {
    private func makeContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: SyncCursor.self, EpisodeStateRecord.self, configurations: configuration)
    }

    private func stubSync(serverChanges: String = "[]", syncedAt: String = "2026-08-18T10:00:00Z", hash: String = "h1") {
        let json = """
        {"serverChanges":\(serverChanges),"syncedAt":"\(syncedAt)","hash":"\(hash)"}
        """.data(using: .utf8)!
        MockURLProtocol.stubHandler = { _ in .success(.init(statusCode: 200, data: json, headers: [:])) }
    }

    func testSyncNowPushesDirtyRecordsAndClearsDirtyFlag() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let record = EpisodeStateRecord(
            id: "ep1", showId: "show1", positionSeconds: 42, completed: false,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000), isDirty: true)
        context.insert(record)
        try context.save()

        stubSync(syncedAt: "2026-08-18T10:00:00Z", hash: "new-hash")
        let engine = SyncEngine(modelContainer: container, adapter: EpisodeSyncAdapter(apiClient: apiClient), deviceId: "device-1")

        await engine.syncNow()

        let requestedURL = try XCTUnwrap(MockURLProtocol.requestedURLs.first)
        XCTAssertTrue(requestedURL.absoluteString.hasSuffix("/api/sync/episodes"))

        let verifyContext = ModelContext(container)
        let stored = try XCTUnwrap(try verifyContext.fetch(FetchDescriptor<EpisodeStateRecord>()).first)
        XCTAssertFalse(stored.isDirty)

        let cursor = try XCTUnwrap(try verifyContext.fetch(FetchDescriptor<SyncCursor>()).first)
        XCTAssertEqual(cursor.localHash, "new-hash")
        XCTAssertEqual(cursor.deviceId, "device-1")
    }

    func testSyncNowSendsDirtyRecordInRequestBody() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(EpisodeStateRecord(
            id: "ep1", showId: "show1", positionSeconds: 42, completed: false,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000), isDirty: true))
        try context.save()

        var capturedBody: Data?
        let json = """
        {"serverChanges":[],"syncedAt":"2026-08-18T10:00:00Z","hash":"h1"}
        """.data(using: .utf8)!
        MockURLProtocol.stubHandler = { request in
            capturedBody = request.capturedBodyData
            return .success(.init(statusCode: 200, data: json, headers: [:]))
        }

        let engine = SyncEngine(modelContainer: container, adapter: EpisodeSyncAdapter(apiClient: apiClient), deviceId: "device-1")
        await engine.syncNow()

        let bodyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(capturedBody)) as? [String: Any])
        XCTAssertEqual(bodyJSON["deviceId"] as? String, "device-1")
        let changes = try XCTUnwrap(bodyJSON["changes"] as? [[String: Any]])
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?["episodeId"] as? String, "ep1")
        XCTAssertEqual(changes.first?["positionSeconds"] as? Int, 42)
    }

    func testSyncNowAppliesServerChangesIntoLocalStore() async throws {
        let container = try makeContainer()

        stubSync(
            serverChanges: """
            [{"episodeId":"ep2","showId":"show2","positionSeconds":99,"completed":true,"updatedAt":"2026-08-18T09:00:00Z"}]
            """,
            hash: "h2")
        let engine = SyncEngine(modelContainer: container, adapter: EpisodeSyncAdapter(apiClient: apiClient), deviceId: "device-1")

        await engine.syncNow()

        let verifyContext = ModelContext(container)
        let stored = try XCTUnwrap(try verifyContext.fetch(FetchDescriptor<EpisodeStateRecord>()).first)
        XCTAssertEqual(stored.id, "ep2")
        XCTAssertEqual(stored.positionSeconds, 99)
        XCTAssertTrue(stored.completed)
        XCTAssertFalse(stored.isDirty)
    }

    func testSyncNowSkipsStoreWriteWhenHashUnchangedAndNothingToSync() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let existingCursor = SyncCursor(domain: "episodes", deviceId: "device-1", lastSyncedAt: Date(timeIntervalSince1970: 1_000), localHash: "same-hash")
        context.insert(existingCursor)
        try context.save()

        stubSync(hash: "same-hash")
        let engine = SyncEngine(modelContainer: container, adapter: EpisodeSyncAdapter(apiClient: apiClient), deviceId: "device-1")

        await engine.syncNow()

        let verifyContext = ModelContext(container)
        let cursor = try XCTUnwrap(try verifyContext.fetch(FetchDescriptor<SyncCursor>()).first)
        // Unchanged: the fast path must not touch lastSyncedAt even though the server response
        // carried a fresh syncedAt.
        XCTAssertEqual(cursor.lastSyncedAt, Date(timeIntervalSince1970: 1_000))
    }

    func testRecordChangedDebouncesMultiplePushesIntoOne() async throws {
        let container = try makeContainer()
        stubSync()
        let engine = SyncEngine(
            modelContainer: container, adapter: EpisodeSyncAdapter(apiClient: apiClient),
            deviceId: "device-1", debounceInterval: .milliseconds(50))

        await engine.recordChanged()
        await engine.recordChanged()
        await engine.recordChanged()

        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(MockURLProtocol.requestedURLs.count, 1)
    }

    func testFailedSyncLeavesDirtyRecordForRetry() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(EpisodeStateRecord(
            id: "ep1", showId: "show1", positionSeconds: 1, completed: false,
            updatedAt: Date(), isDirty: true))
        try context.save()

        MockURLProtocol.stubHandler = { _ in .failure(URLError(.notConnectedToInternet)) }
        let engine = SyncEngine(modelContainer: container, adapter: EpisodeSyncAdapter(apiClient: apiClient), deviceId: "device-1")

        await engine.syncNow()

        let verifyContext = ModelContext(container)
        let stored = try XCTUnwrap(try verifyContext.fetch(FetchDescriptor<EpisodeStateRecord>()).first)
        XCTAssertTrue(stored.isDirty)
    }

    func testWriteAppliesMutationThroughTheEnginesOwnContextAndSchedulesSync() async throws {
        let container = try makeContainer()
        stubSync()
        let engine = SyncEngine(
            modelContainer: container, adapter: EpisodeSyncAdapter(apiClient: apiClient),
            deviceId: "device-1", debounceInterval: .milliseconds(50))

        await engine.write { context in
            context.insert(EpisodeStateRecord(
                id: "ep1", showId: "show1", positionSeconds: 7, completed: false,
                updatedAt: Date(), isDirty: true))
        }

        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(MockURLProtocol.requestedURLs.count, 1)
        let verifyContext = ModelContext(container)
        let stored = try XCTUnwrap(try verifyContext.fetch(FetchDescriptor<EpisodeStateRecord>()).first)
        XCTAssertEqual(stored.positionSeconds, 7)
        XCTAssertFalse(stored.isDirty)
    }

    func testConcurrentWriteDuringInFlightPushIsNotClobbered() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(EpisodeStateRecord(
            id: "ep1", showId: "show1", positionSeconds: 1, completed: false,
            updatedAt: Date(timeIntervalSince1970: 1_000), isDirty: true))
        try context.save()

        let requestReceived = DispatchSemaphore(value: 0)
        let releaseResponse = DispatchSemaphore(value: 0)
        let json = """
        {"serverChanges":[],"syncedAt":"2026-08-18T10:00:00Z","hash":"h1"}
        """.data(using: .utf8)!
        MockURLProtocol.stubHandler = { _ in
            requestReceived.signal()
            releaseResponse.wait()
            return .success(.init(statusCode: 200, data: json, headers: [:]))
        }

        let engine = SyncEngine(modelContainer: container, adapter: EpisodeSyncAdapter(apiClient: apiClient), deviceId: "device-1")
        let syncTask = Task { await engine.syncNow() }

        requestReceived.wait()
        // A second local write lands while the push above is still awaiting its response —
        // actors are reentrant across `await`, so this runs before performSync resumes.
        try await engine.write { context in
            let descriptor = FetchDescriptor<EpisodeStateRecord>(predicate: #Predicate { $0.id == "ep1" })
            let record = try context.fetch(descriptor).first!
            record.positionSeconds = 55
            record.updatedAt = Date(timeIntervalSince1970: 2_000)
            record.isDirty = true
        }
        releaseResponse.signal()
        await syncTask.value

        let verifyContext = ModelContext(container)
        let stored = try XCTUnwrap(try verifyContext.fetch(FetchDescriptor<EpisodeStateRecord>()).first)
        XCTAssertEqual(stored.positionSeconds, 55)
        XCTAssertTrue(stored.isDirty, "the write made during the in-flight push must survive, not get clobbered by the earlier snapshot's isDirty=false")
    }
}
