import SwiftData
import XCTest
@testable import Kuulla

final class PlaylistSyncAdapterTests: MockedApiTestCase {
    private func makeContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: SyncCursor.self, PlaylistRecord.self, PendingPlaylistDownloadRecord.self,
            DownloadedEpisodeRecord.self, configurations: configuration)
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
        XCTAssertEqual(changes.first?["autoDownload"] as? Bool, false)
        let items = try XCTUnwrap(changes.first?["items"] as? [[String: Any]])
        XCTAssertEqual(items.first?["episodeId"] as? String, "ep1")
        XCTAssertEqual(items.first?["order"] as? String, "m")

        let verifyContext = ModelContext(container)
        let stored = try XCTUnwrap(try verifyContext.fetch(FetchDescriptor<PlaylistRecord>()).first)
        XCTAssertFalse(stored.isDirty)
    }

    func testApplyQueuesOnlyNewItemsWhenAutoDownloadIsEnabled() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let originalItem = PlaylistItemRecord(
            episodeId: "ep1", showId: "show1", addedAt: Date(timeIntervalSince1970: 1_600_000_000), order: "m")
        context.insert(PlaylistRecord(
            id: "playlist1", name: "Commute", type: .manual, items: [originalItem],
            createdAt: Date(timeIntervalSince1970: 1_600_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_600_000_000),
            autoDownload: true))
        try context.save()

        var queuedEpisodeIds: [String] = []
        let adapter = PlaylistSyncAdapter(apiClient: apiClient) { items, _ in
            queuedEpisodeIds = items.map(\.episodeId)
        }
        let updated = PlaylistRecord(
            id: "playlist1", name: "Commute", type: .manual,
            items: [
                originalItem,
                PlaylistItemRecord(
                    episodeId: "ep2", showId: "show1",
                    addedAt: Date(timeIntervalSince1970: 1_700_000_000), order: "n"),
            ],
            createdAt: Date(timeIntervalSince1970: 1_600_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            autoDownload: true)

        try adapter.apply(updated, in: context)

        XCTAssertEqual(queuedEpisodeIds, ["ep2"])
    }

    func testApplyDoesNotQueueNewItemsWhenAutoDownloadIsDisabled() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(PlaylistRecord(
            id: "playlist1", name: "Commute", type: .manual, items: [],
            createdAt: Date(timeIntervalSince1970: 1_600_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_600_000_000)))
        try context.save()

        var didQueue = false
        let adapter = PlaylistSyncAdapter(apiClient: apiClient) { _, _ in didQueue = true }
        let updated = PlaylistRecord(
            id: "playlist1", name: "Commute", type: .manual,
            items: [PlaylistItemRecord(
                episodeId: "ep2", showId: "show1",
                addedAt: Date(timeIntervalSince1970: 1_700_000_000), order: "n")],
            createdAt: Date(timeIntervalSince1970: 1_600_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000))

        try adapter.apply(updated, in: context)

        XCTAssertFalse(didQueue)
    }

    func testApplyDoesNotQueueExistingItemsWhenPlaylistFirstSyncs() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        var didQueue = false
        let adapter = PlaylistSyncAdapter(apiClient: apiClient) { _, _ in didQueue = true }
        let incoming = PlaylistRecord(
            id: "playlist1", name: "Commute", type: .manual,
            items: [PlaylistItemRecord(
                episodeId: "ep1", showId: "show1",
                addedAt: Date(timeIntervalSince1970: 1_600_000_000), order: "m")],
            createdAt: Date(timeIntervalSince1970: 1_600_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            autoDownload: true)

        try adapter.apply(incoming, in: context)

        XCTAssertFalse(didQueue)
    }

    func testAutoDownloadPersistsUnresolvedItemForLaterSyncRetry() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        MockURLProtocol.stubHandler = { _ in
            .success(.init(statusCode: 404, data: Data(), headers: [:]))
        }

        PlaylistAutoDownload.enqueue(
            [PlaylistItemRecord(
                episodeId: "ep1", showId: "show1",
                addedAt: Date(timeIntervalSince1970: 1_700_000_000), order: "m")],
            in: context)
        try context.save()

        let pending = try context.fetch(FetchDescriptor<PendingPlaylistDownloadRecord>())
        XCTAssertEqual(pending.map(\.id), ["ep1"])
        XCTAssertEqual(pending.first?.showId, "show1")
    }

    func testAutoDownloadClearsPendingItemThatIsAlreadyDownloaded() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(PendingPlaylistDownloadRecord(id: "ep1", showId: "show1"))
        context.insert(DownloadedEpisodeRecord(
            id: "ep1", showId: "show1", localFilePath: "ep1.mp3", fileSizeBytes: 100,
            downloadedAt: .now, status: .complete))
        try context.save()

        PlaylistAutoDownload.retryPending(in: context)
        try context.save()

        XCTAssertTrue(try context.fetch(FetchDescriptor<PendingPlaylistDownloadRecord>()).isEmpty)
    }

    func testAutoDownloadKeepsPendingItemWhileDownloadIsNotYetDurable() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(PendingPlaylistDownloadRecord(id: "ep1", showId: "show1"))
        context.insert(DownloadedEpisodeRecord(
            id: "ep1", showId: "show1", localFilePath: "", fileSizeBytes: 0,
            downloadedAt: .now, status: .downloading))
        try context.save()

        PlaylistAutoDownload.retryPending(in: context)
        try context.save()

        XCTAssertEqual(
            try context.fetch(FetchDescriptor<PendingPlaylistDownloadRecord>()).map(\.id),
            ["ep1"])
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

    // #114: dynamic playlist item changes (auto-insert/evict, #112) are whole-document Playlist
    // updates on the server, not the granular per-item changes manual reordering produces —
    // verify apply(record:in:) replaces the existing record's items/dynamicConfig wholesale with
    // whatever the server sent, rather than merging, so a server-side insert or eviction round-
    // trips correctly.
    func testApplyReplacesItemsAndDynamicConfigOnDynamicPlaylistUpdate() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let originalItem = PlaylistItemRecord(
            episodeId: "ep1", showId: "show1", addedAt: Date(timeIntervalSince1970: 1_600_000_000), order: "m")
        context.insert(PlaylistRecord(
            id: "dynamic1", name: "Auto Mix", type: .dynamic, items: [originalItem],
            createdAt: Date(timeIntervalSince1970: 1_600_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_600_000_000),
            isDirty: false,
            dynamicConfig: DynamicPlaylistConfigRecord(showIds: ["show1"], maxEpisodes: 5, priorityList: ["show1"])))
        try context.save()

        // Server auto-inserted "ep2" ahead of "ep1" and evicted nothing yet — a whole-document
        // replacement of Items, exactly what EpisodeService.InsertIntoDynamicPlaylistsAsync's
        // optimistic-concurrency upsert produces.
        let adapter = PlaylistSyncAdapter(apiClient: apiClient)
        let updated = PlaylistRecord(
            id: "dynamic1", name: "Auto Mix", type: .dynamic,
            items: [
                PlaylistItemRecord(episodeId: "ep2", showId: "show1", addedAt: Date(timeIntervalSince1970: 1_700_000_000), order: "b"),
                PlaylistItemRecord(episodeId: "ep1", showId: "show1", addedAt: Date(timeIntervalSince1970: 1_600_000_000), order: "m"),
            ],
            createdAt: Date(timeIntervalSince1970: 1_600_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            dynamicConfig: DynamicPlaylistConfigRecord(showIds: ["show1"], maxEpisodes: 2, priorityList: ["show1"]))

        try adapter.apply(updated, in: context)

        let stored = try XCTUnwrap(try context.fetch(FetchDescriptor<PlaylistRecord>()).first)
        XCTAssertEqual(stored.items.map(\.episodeId), ["ep2", "ep1"])
        XCTAssertEqual(stored.dynamicConfig?.maxEpisodes, 2)
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

    // #400: a server change with deleted == true is a tombstone for a playlist removed on another
    // device — apply(record:in:) deletes the local row outright.
    func testApplyDeletesLocalRecordOnTombstone() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(PlaylistRecord(
            id: "playlist1", name: "Commute", type: .manual, items: [],
            createdAt: Date(timeIntervalSince1970: 1_000), updatedAt: Date(timeIntervalSince1970: 1_000), isDirty: true))
        try context.save()

        let adapter = PlaylistSyncAdapter(apiClient: apiClient)
        let tombstone = PlaylistRecord(
            id: "playlist1", name: "Commute", type: .manual, items: [],
            createdAt: Date(timeIntervalSince1970: 1_000), updatedAt: Date(timeIntervalSince1970: 2_000_000_000),
            deleted: true)

        try adapter.apply(tombstone, in: context)

        XCTAssertTrue(try context.fetch(FetchDescriptor<PlaylistRecord>()).isEmpty)
    }

    func testApplyTombstoneForUnknownPlaylistIsANoOp() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let adapter = PlaylistSyncAdapter(apiClient: apiClient)
        let tombstone = PlaylistRecord(
            id: "never-seen", name: "Ghost", type: .manual, items: [],
            createdAt: Date(timeIntervalSince1970: 1_000), updatedAt: Date(timeIntervalSince1970: 2_000_000_000),
            deleted: true)

        try adapter.apply(tombstone, in: context)

        XCTAssertTrue(try context.fetch(FetchDescriptor<PlaylistRecord>()).isEmpty)
    }

    func testSyncNowAppliesTombstoneFromServerResponse() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(PlaylistRecord(
            id: "playlist1", name: "Commute", type: .manual, items: [],
            createdAt: Date(timeIntervalSince1970: 1_000), updatedAt: Date(timeIntervalSince1970: 1_000)))
        try context.save()

        stubSync(serverChanges: """
        [{"id":"playlist1","name":"Commute","type":0,"items":[],"createdAt":"2020-01-01T00:00:00Z","updatedAt":"2026-08-19T09:00:00Z","dynamicConfig":null,"icon":null,"accentColor":null,"deleted":true}]
        """)

        let engine = SyncEngine(modelContainer: container, adapter: PlaylistSyncAdapter(apiClient: apiClient), deviceId: "device-1")
        await engine.syncNow()

        let freshContext = ModelContext(container)
        XCTAssertTrue(try freshContext.fetch(FetchDescriptor<PlaylistRecord>()).isEmpty)
    }
}
