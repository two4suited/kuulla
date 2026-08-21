import XCTest
@testable import Kuulla

final class PlaylistClientTests: MockedApiTestCase {
    private var client: PlaylistClient { PlaylistClient(apiClient: apiClient) }

    func testGetPlaylistsDecodesResponse() async throws {
        let json = """
        [{"id":"p1","userId":"u1","name":"Commute","type":0,"items":[],"createdAt":"2026-08-19T10:00:00+00:00","updatedAt":"2026-08-19T10:00:00+00:00"}]
        """.data(using: .utf8)!
        MockURLProtocol.stubHandler = { _ in .success(.init(statusCode: 200, data: json, headers: [:])) }

        let playlists = try await client.getPlaylists()

        XCTAssertEqual(playlists.map(\.name), ["Commute"])
    }

    func testCreatePlaylistSendsNameAndDecodesResponse() async throws {
        let json = """
        {"id":"p1","userId":"u1","name":"New Playlist","type":0,"items":[],"createdAt":"2026-08-19T10:00:00+00:00","updatedAt":"2026-08-19T10:00:00+00:00"}
        """.data(using: .utf8)!
        var capturedBody: Data?
        MockURLProtocol.stubHandler = { request in
            capturedBody = request.capturedBodyData
            return .success(.init(statusCode: 200, data: json, headers: [:]))
        }

        let playlist = try await client.createPlaylist(name: "New Playlist")

        XCTAssertEqual(playlist.name, "New Playlist")
        let bodyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(capturedBody)) as? [String: Any])
        XCTAssertEqual(bodyJSON["name"] as? String, "New Playlist")
    }

    func testCreateDynamicPlaylistSendsConfigAndDecodesResponse() async throws {
        let json = """
        {"id":"p1","userId":"u1","name":"New Dynamic Playlist","type":1,"items":[],"createdAt":"2026-08-19T10:00:00+00:00","updatedAt":"2026-08-19T10:00:00+00:00","dynamicConfig":{"showIds":["show1","show2"],"maxEpisodes":10,"priorityList":["show1","show2"]}}
        """.data(using: .utf8)!
        var capturedBody: Data?
        MockURLProtocol.stubHandler = { request in
            capturedBody = request.capturedBodyData
            return .success(.init(statusCode: 200, data: json, headers: [:]))
        }

        let config = DynamicPlaylistConfig(showIds: ["show1", "show2"], maxEpisodes: 10, priorityList: ["show1", "show2"])
        let playlist = try await client.createDynamicPlaylist(name: "New Dynamic Playlist", config: config)

        XCTAssertEqual(playlist.type, .dynamic)
        let bodyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(capturedBody)) as? [String: Any])
        XCTAssertEqual((bodyJSON["type"] as? Int), 1)
        XCTAssertEqual((bodyJSON["dynamicConfig"] as? [String: Any])?["maxEpisodes"] as? Int, 10)
    }

    func testUpdateDynamicPlaylistConfigSendsConfig() async throws {
        let json = """
        {"id":"p1","userId":"u1","name":"Update","type":1,"items":[],"createdAt":"2026-08-19T10:00:00+00:00","updatedAt":"2026-08-19T10:00:00+00:00","dynamicConfig":{"showIds":["show1","show2"],"maxEpisodes":6,"priorityList":["show2","show1"]}}
        """.data(using: .utf8)!
        var capturedBody: Data?
        MockURLProtocol.stubHandler = { request in
            capturedBody = request.capturedBodyData
            return .success(.init(statusCode: 200, data: json, headers: [:]))
        }

        let config = DynamicPlaylistConfig(showIds: ["show1", "show2"], maxEpisodes: 6, priorityList: ["show2", "show1"])
        let updated = try await client.updateDynamicPlaylistConfig(id: "p1", config: config)

        XCTAssertEqual(updated?.dynamicConfig?.maxEpisodes, 6)
        let bodyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(capturedBody)) as? [String: Any])
        XCTAssertEqual((bodyJSON["priorityList"] as? [String]), ["show2", "show1"])
    }

    func testGetPlaylistDetailReturnsNilOn404() async throws {
        MockURLProtocol.stubHandler = { _ in .success(.init(statusCode: 404, data: Data(), headers: [:])) }

        let detail = try await client.getPlaylistDetail(id: "missing")

        XCTAssertNil(detail)
    }

    func testGetPlaylistDetailDecodesResolvedItems() async throws {
        let json = """
        {"id":"p1","name":"Commute","type":0,"items":[{"episodeId":"ep1","showId":"show1","title":"Episode One","artworkUrl":null,"addedAt":"2026-08-19T10:00:00+00:00","order":"m"}],"createdAt":"2026-08-19T10:00:00+00:00","updatedAt":"2026-08-19T10:00:00+00:00"}
        """.data(using: .utf8)!
        MockURLProtocol.stubHandler = { _ in .success(.init(statusCode: 200, data: json, headers: [:])) }

        let detail = try await client.getPlaylistDetail(id: "p1")

        XCTAssertEqual(detail?.items.first?.title, "Episode One")
    }

    func testRemoveItemEscapesEpisodeIdAndUsesDelete() async throws {
        MockURLProtocol.stubHandler = { _ in .success(.init(statusCode: 200, data: Data(), headers: [:])) }

        try await client.removeItem(playlistId: "p1", episodeId: "a/b")

        let requestedURL = try XCTUnwrap(MockURLProtocol.requestedURLs.first)
        XCTAssertTrue(requestedURL.absoluteString.contains("a%2Fb"))
    }

    func testReorderItemSendsNeighborIds() async throws {
        let json = """
        {"id":"p1","userId":"u1","name":"Commute","type":0,"items":[],"createdAt":"2026-08-19T10:00:00+00:00","updatedAt":"2026-08-19T10:00:00+00:00"}
        """.data(using: .utf8)!
        var capturedBody: Data?
        MockURLProtocol.stubHandler = { request in
            capturedBody = request.capturedBodyData
            return .success(.init(statusCode: 200, data: json, headers: [:]))
        }

        try await client.reorderItem(playlistId: "p1", episodeId: "ep1", beforeEpisodeId: "ep0", afterEpisodeId: "ep2")

        let bodyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(capturedBody)) as? [String: Any])
        XCTAssertEqual(bodyJSON["beforeEpisodeId"] as? String, "ep0")
        XCTAssertEqual(bodyJSON["afterEpisodeId"] as? String, "ep2")
    }
}
