import SwiftData
import XCTest
@testable import Kuulla

final class PlaylistSyncAdapterTests: MockedApiTestCase {
    private func makeContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: SyncCursor.self, PlaylistRecord.self, configurations: configuration)
    }

    private func stubSync(serverChanges: String = "[]", syncedAt: String = "2026-08-19T10:00:00Z", hash: String = "h1") {
        let json = """
        {"serverChanges":\(serverChanges),"syncedAt":"\(syncedAt)","hash":"\(hash)"}
        """.data(using: .utf8)!
        MockURLProtocol.stubHandler = { _ in .success(.init(statusCode: 200, data: json, headers: [:])) }
    }

    func testSyncNowSendsDirtyPlaylistWithEmbeddedItemsInRequestBody() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let item = PlaylistItemRecord(episodeId: "ep1", showId: "show1", addedAt: Date(timeIntervalSince1970: 1_700_000_000), order: "m")
        context.insert(PlaylistRecord(
            id: "playlist1", name: "Commute", type: .manual, items: [item],
            createdAt: Date(timeIntervalSince1970: 1_600_000_000), updatedAt: Date(timeIntervalSince1970: 1_700_000_000), isDirty: true))
        try context.save()

        var capturedBody: Data?
        let json = """
        {"serverChanges":[],"syncedAt":"2026-08-19T10:00:00Z","hash":"h1"}
        """.data(using: .utf8)!
        MockURLProtocol.stubHandler = { request in
            capturedBody = request.capturedBodyData
            return .success(.init(statusCode: 200, data: json, headers: [:]))
        }

        let engine = SyncEngine(modelContainer: container, adapter: PlaylistSyncAdapter(apiClient: apiClient), deviceId: "device-1")
        await engine.syncNow()

        let requestedURL = try XCTUnwrap(MockURLProtocol.requestedURLs.first)
        XCTAssertTrue(requestedURL.absoluteString.hasSuffix("/api/sync/playlists"))

        let bodyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(capturedBody)) as? [String: Any])
        XCTAssertEqual(bodyJSON["deviceId"] as? String, "device-1")
        let changes = try XCTUnwrap(bodyJSON["changes"] as? [[String: Any]])
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?["name"] as? String, "Commute")
        XCTAssertEqual(changes.first?["type"] as? Int, 0)
        let items = try XCTUnwrap(changes.first?["items"] as? [[String: Any]])
        XCTAssertEqual(items.first?["episodeId"] as? String, "ep1")
        XCTAssertEqual(items.first?["order"] as? String, "m")

        let verifyContext = ModelContext(container)
        let stored = try XCTUnwrap(try verifyContext.fetch(FetchDescriptor<PlaylistRecord>()).first)
        XCTAssertFalse(stored.isDirty)
    }

    func testSyncNowAppliesServerChangesIntoLocalStore() async throws {
        let container = try makeContainer()

        stubSync(
            serverChanges: """
            [{"id":"playlist2","name":"Weekend","type":0,"items":[{"episodeId":"ep2","showId":"show2","addedAt":"2026-08-19T09:00:00Z","order":"b"}],"createdAt":"2026-08-18T09:00:00Z","updatedAt":"2026-08-19T09:00:00Z"}]
            """,
            hash: "h2")
        let engine = SyncEngine(modelContainer: container, adapter: PlaylistSyncAdapter(apiClient: apiClient), deviceId: "device-1")

        await engine.syncNow()

        let verifyContext = ModelContext(container)
        let stored = try XCTUnwrap(try verifyContext.fetch(FetchDescriptor<PlaylistRecord>()).first)
        XCTAssertEqual(stored.id, "playlist2")
        XCTAssertEqual(stored.name, "Weekend")
        XCTAssertEqual(stored.items.count, 1)
        XCTAssertEqual(stored.items.first?.episodeId, "ep2")
        XCTAssertFalse(stored.isDirty)
    }

    func testApplyDiscardsServerChangeOlderThanStoredRecord() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let newer = Date(timeIntervalSince1970: 2_000_000_000)
        context.insert(PlaylistRecord(
            id: "playlist1", name: "Local Name", type: .manual, items: [],
            createdAt: Date(timeIntervalSince1970: 1_000), updatedAt: newer, isDirty: false))
        try context.save()

        let adapter = PlaylistSyncAdapter(apiClient: apiClient)
        let stale = PlaylistRecord(
            id: "playlist1", name: "Stale Name", type: .manual, items: [],
            createdAt: Date(timeIntervalSince1970: 1_000), updatedAt: Date(timeIntervalSince1970: 1_000_000_000))

        try adapter.apply(stale, in: context)

        let stored = try XCTUnwrap(try context.fetch(FetchDescriptor<PlaylistRecord>()).first)
        XCTAssertEqual(stored.name, "Local Name")
    }
}
