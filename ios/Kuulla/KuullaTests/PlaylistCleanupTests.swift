import SwiftData
import XCTest
@testable import Kuulla

final class PlaylistCleanupTests: MockedApiTestCase {
    private var client: PlaylistClient { PlaylistClient(apiClient: apiClient) }

    private func makeContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: SyncCursor.self, PlaylistRecord.self, configurations: configuration)
    }

    private func makeEngine(_ container: ModelContainer) -> SyncEngine<PlaylistSyncAdapter> {
        SyncEngine(modelContainer: container, adapter: PlaylistSyncAdapter(apiClient: apiClient), deviceId: "device-1")
    }

    private func insertPlaylist(
        _ id: String, type: PlaylistType, items: [(episodeId: String, showId: String)], in context: ModelContext
    ) {
        let records = items.map {
            PlaylistItemRecord(
                episodeId: $0.episodeId, showId: $0.showId,
                addedAt: Date(timeIntervalSince1970: 1_700_000_000), order: "a")
        }
        context.insert(PlaylistRecord(
            id: id, name: "P", type: type, items: records,
            createdAt: Date(timeIntervalSince1970: 1_600_000_000), updatedAt: Date(timeIntervalSince1970: 1_700_000_000)))
    }

    private func fetchPlaylist(_ id: String, in container: ModelContainer) throws -> PlaylistRecord {
        let context = ModelContext(container)
        return try XCTUnwrap(try context.fetch(FetchDescriptor<PlaylistRecord>(
            predicate: #Predicate { $0.id == id }
        )).first)
    }

    func testRemoveFromManualPlaylistsSkipsWhenNotCompleted() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        insertPlaylist("p1", type: .manual, items: [(episodeId: "e1", showId: "s1")], in: context)
        try context.save()
        let engine = makeEngine(container)

        MockURLProtocol.stubHandler = { _ in
            XCTFail("Should not make any network request when not completed")
            return .success(.init(statusCode: 200, data: Data(), headers: [:]))
        }

        await PlaylistCleanup.removeFromManualPlaylists(
            episodeId: "e1", completed: false, playlistSyncEngine: engine, playlistClient: client)

        let p1 = try fetchPlaylist("p1", in: container)
        XCTAssertEqual(p1.items.count, 1)
    }

    func testRemoveFromManualPlaylistsRemovesLocallyAndDeletesFromEachContainingManualPlaylist() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        insertPlaylist("p1", type: .manual, items: [(episodeId: "e1", showId: "s1")], in: context)
        insertPlaylist("p2", type: .manual, items: [(episodeId: "other", showId: "s1")], in: context)
        insertPlaylist("p3", type: .dynamic, items: [(episodeId: "e1", showId: "s1")], in: context)
        try context.save()
        let engine = makeEngine(container)

        var deletedURLs: [URL] = []
        MockURLProtocol.stubHandler = { request in
            if request.httpMethod == "GET" {
                return .success(.init(statusCode: 200, data: Data("[]".utf8), headers: [:]))
            }
            XCTAssertEqual(request.httpMethod, "DELETE")
            deletedURLs.append(request.url!)
            return .success(.init(statusCode: 204, data: Data(), headers: [:]))
        }

        await PlaylistCleanup.removeFromManualPlaylists(
            episodeId: "e1", completed: true, playlistSyncEngine: engine, playlistClient: client)

        // Local removal happens synchronously, before any network round trip.
        let p1 = try fetchPlaylist("p1", in: container)
        XCTAssertTrue(p1.items.isEmpty)
        let p3 = try fetchPlaylist("p3", in: container)
        XCTAssertEqual(p3.items.count, 1, "dynamic playlists aren't editable locally")

        XCTAssertEqual(deletedURLs.count, 1)
        XCTAssertTrue(deletedURLs[0].path.contains("/playlists/p1/items/e1"))
    }

    // Regression test for #771: the local removal must mark the record dirty and bump updatedAt
    // even when the DELETE succeeds — otherwise a sync pull racing the DELETE could see a stale
    // (higher) server updatedAt and overwrite `items`, silently resurrecting the removed episode.
    func testRemoveFromManualPlaylistsMarksRecordDirtyAndBumpsUpdatedAtEvenWhenDeleteSucceeds() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let originalUpdatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        context.insert(PlaylistRecord(
            id: "p1", name: "P", type: .manual,
            items: [PlaylistItemRecord(episodeId: "e1", showId: "s1", addedAt: originalUpdatedAt, order: "a")],
            createdAt: Date(timeIntervalSince1970: 1_600_000_000), updatedAt: originalUpdatedAt))
        try context.save()
        let engine = makeEngine(container)

        MockURLProtocol.stubHandler = { request in
            if request.httpMethod == "GET" {
                return .success(.init(statusCode: 200, data: Data("[]".utf8), headers: [:]))
            }
            return .success(.init(statusCode: 204, data: Data(), headers: [:]))
        }

        await PlaylistCleanup.removeFromManualPlaylists(
            episodeId: "e1", completed: true, playlistSyncEngine: engine, playlistClient: client)

        let p1 = try fetchPlaylist("p1", in: container)
        XCTAssertTrue(p1.isDirty, "the local edit must be marked dirty regardless of the DELETE's outcome")
        XCTAssertGreaterThan(p1.updatedAt, originalUpdatedAt, "updatedAt must advance so last-write-wins can't clobber this removal with stale server state")
    }

    func testRemoveFromManualPlaylistsMarksRecordDirtyWhenDeleteFails() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        insertPlaylist("p1", type: .manual, items: [(episodeId: "e1", showId: "s1")], in: context)
        try context.save()
        let engine = makeEngine(container)

        MockURLProtocol.stubHandler = { request in
            if request.httpMethod == "GET" {
                return .success(.init(statusCode: 200, data: Data("[]".utf8), headers: [:]))
            }
            return .success(.init(statusCode: 500, data: Data(), headers: [:]))
        }

        await PlaylistCleanup.removeFromManualPlaylists(
            episodeId: "e1", completed: true, playlistSyncEngine: engine, playlistClient: client)

        let p1 = try fetchPlaylist("p1", in: container)
        XCTAssertTrue(p1.items.isEmpty, "local removal happens regardless of the DELETE's outcome")
        XCTAssertTrue(p1.isDirty, "a failed DELETE should mark the record dirty so the next sync pushes the removal")
    }

    func testRemoveFromManualPlaylistsFallsBackToServerWhenLocalPlaylistIsMissing() async throws {
        let container = try makeContainer()
        let engine = makeEngine(container)
        let playlistJSON = """
        [{"id":"p1","userId":"u1","name":"P","type":0,"items":[{"episodeId":"e1","showId":"s1","addedAt":"2026-08-19T10:00:00+00:00","order":"a"}],"createdAt":"2026-08-19T10:00:00+00:00","updatedAt":"2026-08-19T10:00:00+00:00"}]
        """.data(using: .utf8)!

        MockURLProtocol.stubHandler = { request in
            if request.httpMethod == "GET" {
                return .success(.init(statusCode: 200, data: playlistJSON, headers: [:]))
            }
            XCTAssertEqual(request.httpMethod, "DELETE")
            return .success(.init(statusCode: 204, data: Data(), headers: [:]))
        }

        await PlaylistCleanup.removeFromManualPlaylists(
            episodeId: "e1", completed: true, playlistSyncEngine: engine, playlistClient: client)

        XCTAssertEqual(MockURLProtocol.requestedURLs.count, 2)
        XCTAssertTrue(MockURLProtocol.requestedURLs.contains { $0.path.contains("/playlists/p1/items/e1") })
    }

    func testRemoveFromManualPlaylistsAlsoDeletesServerOnlyPlaylistWhenLocalStoreHasAnotherMatch() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        insertPlaylist("local", type: .manual, items: [(episodeId: "e1", showId: "s1")], in: context)
        try context.save()
        let engine = makeEngine(container)
        let playlistJSON = """
        [{"id":"server-only","userId":"u1","name":"P","type":0,"items":[{"episodeId":"e1","showId":"s1","addedAt":"2026-08-19T10:00:00+00:00","order":"a"}],"createdAt":"2026-08-19T10:00:00+00:00","updatedAt":"2026-08-19T10:00:00+00:00"}]
        """.data(using: .utf8)!

        MockURLProtocol.stubHandler = { request in
            if request.httpMethod == "GET" {
                return .success(.init(statusCode: 200, data: playlistJSON, headers: [:]))
            }
            XCTAssertEqual(request.httpMethod, "DELETE")
            return .success(.init(statusCode: 204, data: Data(), headers: [:]))
        }

        await PlaylistCleanup.removeFromManualPlaylists(
            episodeId: "e1", completed: true, playlistSyncEngine: engine, playlistClient: client)

        XCTAssertTrue(MockURLProtocol.requestedURLs.contains { $0.path.contains("/playlists/local/items/e1") })
        XCTAssertTrue(MockURLProtocol.requestedURLs.contains { $0.path.contains("/playlists/server-only/items/e1") })
    }

    func testRemoveAllFromManualPlaylistsRemovesEveryItemForShow() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        insertPlaylist(
            "p1", type: .manual,
            items: [(episodeId: "e1", showId: "s1"), (episodeId: "e2", showId: "s1")], in: context)
        insertPlaylist("p2", type: .manual, items: [(episodeId: "e3", showId: "other-show")], in: context)
        insertPlaylist("p3", type: .dynamic, items: [(episodeId: "e4", showId: "s1")], in: context)
        try context.save()
        let engine = makeEngine(container)

        var deletedPaths: Set<String> = []
        MockURLProtocol.stubHandler = { request in
            if request.httpMethod == "GET" {
                return .success(.init(statusCode: 200, data: Data("[]".utf8), headers: [:]))
            }
            deletedPaths.insert(request.url!.path)
            return .success(.init(statusCode: 204, data: Data(), headers: [:]))
        }

        await PlaylistCleanup.removeAllFromManualPlaylists(
            forShowId: "s1", playlistSyncEngine: engine, playlistClient: client)

        XCTAssertEqual(deletedPaths, [
            "/api/playlists/p1/items/e1",
            "/api/playlists/p1/items/e2",
        ])

        let p1 = try fetchPlaylist("p1", in: container)
        XCTAssertTrue(p1.items.isEmpty)
        let p2 = try fetchPlaylist("p2", in: container)
        XCTAssertEqual(p2.items.count, 1)
        let p3 = try fetchPlaylist("p3", in: container)
        XCTAssertEqual(p3.items.count, 1, "dynamic playlists aren't editable locally")
    }
}
