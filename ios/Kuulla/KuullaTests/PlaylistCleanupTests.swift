import XCTest
@testable import Kuulla

final class PlaylistCleanupTests: MockedApiTestCase {
    private var client: PlaylistClient { PlaylistClient(apiClient: apiClient) }

    private func playlistsJSON(_ playlists: [(id: String, type: Int, items: [(episodeId: String, showId: String)])]) -> Data {
        let playlistsJSON = playlists.map { playlist -> String in
            let itemsJSON = playlist.items.map { item in
                """
                {"episodeId":"\(item.episodeId)","showId":"\(item.showId)","addedAt":"2026-08-19T10:00:00+00:00","order":"a"}
                """
            }.joined(separator: ",")
            return """
            {"id":"\(playlist.id)","userId":"u1","name":"P","type":\(playlist.type),"items":[\(itemsJSON)],"createdAt":"2026-08-19T10:00:00+00:00","updatedAt":"2026-08-19T10:00:00+00:00"}
            """
        }.joined(separator: ",")
        return "[\(playlistsJSON)]".data(using: .utf8)!
    }

    func testRemoveFromManualPlaylistsSkipsWhenNotCompleted() async throws {
        MockURLProtocol.stubHandler = { _ in
            XCTFail("Should not make any network request when not completed")
            return .success(.init(statusCode: 200, data: Data(), headers: [:]))
        }

        await PlaylistCleanup.removeFromManualPlaylists(episodeId: "e1", completed: false, playlistClient: client)
    }

    func testRemoveFromManualPlaylistsRemovesFromEachContainingManualPlaylist() async throws {
        let json = playlistsJSON([
            (id: "p1", type: 0, items: [(episodeId: "e1", showId: "s1")]),
            (id: "p2", type: 0, items: [(episodeId: "other", showId: "s1")]),
            (id: "p3", type: 1, items: [(episodeId: "e1", showId: "s1")]),
        ])
        var deletedURLs: [URL] = []
        MockURLProtocol.stubHandler = { request in
            if request.httpMethod == "DELETE" {
                deletedURLs.append(request.url!)
                return .success(.init(statusCode: 204, data: Data(), headers: [:]))
            }
            return .success(.init(statusCode: 200, data: json, headers: [:]))
        }

        await PlaylistCleanup.removeFromManualPlaylists(episodeId: "e1", completed: true, playlistClient: client)

        XCTAssertEqual(deletedURLs.count, 1)
        XCTAssertTrue(deletedURLs[0].path.contains("/playlists/p1/items/e1"))
    }

    func testRemoveAllFromManualPlaylistsRemovesEveryItemForShow() async throws {
        let json = playlistsJSON([
            (id: "p1", type: 0, items: [(episodeId: "e1", showId: "s1"), (episodeId: "e2", showId: "s1")]),
            (id: "p2", type: 0, items: [(episodeId: "e3", showId: "other-show")]),
            (id: "p3", type: 1, items: [(episodeId: "e4", showId: "s1")]),
        ])
        var deletedURLs: [URL] = []
        MockURLProtocol.stubHandler = { request in
            if request.httpMethod == "DELETE" {
                deletedURLs.append(request.url!)
                return .success(.init(statusCode: 204, data: Data(), headers: [:]))
            }
            return .success(.init(statusCode: 200, data: json, headers: [:]))
        }

        await PlaylistCleanup.removeAllFromManualPlaylists(forShowId: "s1", playlistClient: client)

        XCTAssertEqual(Set(deletedURLs.map(\.path)), [
            "/api/playlists/p1/items/e1",
            "/api/playlists/p1/items/e2",
        ])
    }
}
