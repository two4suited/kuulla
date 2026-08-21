import Foundation

// Direct CRUD against /api/playlists, coexisting with PlaylistSyncAdapter (sync push) exactly as
// SubscriptionClient (direct CRUD) coexists with EpisodeSyncAdapter (sync) for episodes.
struct PlaylistClient {
    private let apiClient: ApiClient

    init(apiClient: ApiClient = .shared) {
        self.apiClient = apiClient
    }

    func getPlaylists() async throws -> [Playlist] {
        try await apiClient.get(["api", "playlists"])
    }

    func createPlaylist(name: String) async throws -> Playlist {
        try await apiClient.post(["api", "playlists"], body: CreatePlaylistRequest(name: name))
    }

    func createDynamicPlaylist(name: String, config: DynamicPlaylistConfig) async throws -> Playlist {
        try await apiClient.post(
            ["api", "playlists"],
            body: CreateDynamicPlaylistRequest(name: name, type: .dynamic, dynamicConfig: config))
    }

    func updateDynamicPlaylistConfig(id: String, config: DynamicPlaylistConfig) async throws -> Playlist? {
        do {
            return try await apiClient.put(["api", "playlists", id, "config"], body: config)
        } catch ApiError.requestFailed(let statusCode) where statusCode == 404 {
            return nil
        }
    }

    func getPlaylistDetail(id: String) async throws -> PlaylistDetail? {
        do {
            return try await apiClient.get(["api", "playlists", id])
        } catch ApiError.requestFailed(let statusCode) where statusCode == 404 {
            return nil
        }
    }

    func renamePlaylist(id: String, name: String) async throws -> Playlist? {
        do {
            return try await apiClient.put(["api", "playlists", id], body: RenamePlaylistRequest(name: name))
        } catch ApiError.requestFailed(let statusCode) where statusCode == 404 {
            return nil
        }
    }

    func deletePlaylist(id: String) async throws {
        try await apiClient.delete(["api", "playlists", id])
    }

    func addItem(playlistId: String, episodeId: String, showId: String) async throws {
        let _: Playlist = try await apiClient.post(
            ["api", "playlists", playlistId, "items"],
            body: AddPlaylistItemRequest(episodeId: episodeId, showId: showId))
    }

    func removeItem(playlistId: String, episodeId: String) async throws {
        try await apiClient.delete(["api", "playlists", playlistId, "items", episodeId])
    }

    func reorderItem(
        playlistId: String, episodeId: String, beforeEpisodeId: String?, afterEpisodeId: String?
    ) async throws {
        let _: Playlist = try await apiClient.put(
            ["api", "playlists", playlistId, "items", episodeId, "order"],
            body: ReorderPlaylistItemRequest(beforeEpisodeId: beforeEpisodeId, afterEpisodeId: afterEpisodeId))
    }
}

// The bare wire shape returned by list/create/rename/add-item/remove-item/reorder endpoints —
// distinct from PlaylistDetail, which is GET /{id}'s title/artwork-resolved shape.
struct Playlist: Codable, Identifiable {
    let id: String
    let userId: String
    let name: String
    let type: PlaylistType
    let items: [PlaylistItemRecord]
    let createdAt: Date
    let updatedAt: Date
    var dynamicConfig: DynamicPlaylistConfig?
}

// GET /api/playlists/{id}'s response — items resolved against the episodes/shows containers for
// title/artwork. `items` is `var` so callers can mutate a loaded PlaylistDetail's item list
// in-place (optimistic remove/reorder) without round-tripping through a rebuild helper.
struct PlaylistDetail: Decodable, Identifiable {
    let id: String
    let name: String
    let type: PlaylistType
    var items: [PlaylistItemDetail]
    let createdAt: Date
    let updatedAt: Date
    var dynamicConfig: DynamicPlaylistConfig?
}

struct DynamicPlaylistConfig: Codable, Equatable {
    var showIds: [String]
    // Nil means unlimited — mirrors the server's nullable Kuulla.Api.Models.DynamicPlaylistConfig.MaxEpisodes.
    var maxEpisodes: Int?
    var priorityList: [String]
}

struct PlaylistItemDetail: Decodable, Identifiable {
    let episodeId: String
    let showId: String
    let title: String?
    let artworkUrl: String?
    let addedAt: Date
    let order: String

    var id: String { episodeId }
}

private struct CreatePlaylistRequest: Encodable {
    let name: String
}

private struct CreateDynamicPlaylistRequest: Encodable {
    let name: String
    let type: PlaylistType
    let dynamicConfig: DynamicPlaylistConfig
}

private struct RenamePlaylistRequest: Encodable {
    let name: String
}

private struct AddPlaylistItemRequest: Encodable {
    let episodeId: String
    let showId: String
}

private struct ReorderPlaylistItemRequest: Encodable {
    let beforeEpisodeId: String?
    let afterEpisodeId: String?
}
