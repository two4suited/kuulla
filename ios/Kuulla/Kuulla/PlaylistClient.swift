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

    func createPlaylist(name: String, icon: String? = nil, accentColor: String? = nil) async throws -> Playlist {
        try await apiClient.post(
            ["api", "playlists"],
            body: CreatePlaylistRequest(name: name, icon: icon, accentColor: accentColor))
    }

    func createDynamicPlaylist(
        name: String, config: DynamicPlaylistConfig, icon: String? = nil, accentColor: String? = nil
    ) async throws -> Playlist {
        try await apiClient.post(
            ["api", "playlists"],
            body: CreateDynamicPlaylistRequest(
                name: name, type: .dynamic, dynamicConfig: config, icon: icon, accentColor: accentColor))
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

    // PUT /api/playlists/{id} sets the playlist's full display state — pass the current
    // icon/accentColor when only the name changes, or they'll be cleared.
    func renamePlaylist(
        id: String, name: String, icon: String? = nil, accentColor: String? = nil
    ) async throws -> Playlist? {
        do {
            return try await apiClient.put(
                ["api", "playlists", id],
                body: RenamePlaylistRequest(name: name, icon: icon, accentColor: accentColor))
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
    var icon: String?
    var accentColor: String?
}

// GET /api/playlists/{id}'s response — items resolved against the episodes/shows containers for
// title/artwork. `items` is `var` so callers can mutate a loaded PlaylistDetail's item list
// in-place (optimistic remove/reorder) without round-tripping through a rebuild helper.
struct PlaylistDetail: Decodable, Identifiable {
    let id: String
    // var so the edit-playlist flow can reflect a rename in-place without a full reload.
    var name: String
    let type: PlaylistType
    var items: [PlaylistItemDetail]
    let createdAt: Date
    let updatedAt: Date
    var dynamicConfig: DynamicPlaylistConfig?
    var icon: String?
    var accentColor: String?
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
    let icon: String?
    let accentColor: String?
}

private struct CreateDynamicPlaylistRequest: Encodable {
    let name: String
    let type: PlaylistType
    let dynamicConfig: DynamicPlaylistConfig
    let icon: String?
    let accentColor: String?
}

private struct RenamePlaylistRequest: Encodable {
    let name: String
    let icon: String?
    let accentColor: String?
}

private struct AddPlaylistItemRequest: Encodable {
    let episodeId: String
    let showId: String
}

private struct ReorderPlaylistItemRequest: Encodable {
    let beforeEpisodeId: String?
    let afterEpisodeId: String?
}

// #569: mirrors DownloadCleanup's shared entry point (DownloadsView.swift) — every place that can
// mark an episode played manually (EpisodeDetailView.persist, ShowDetailView.toggleCompleted, the
// "mark all played" bulk flow) goes through the same rule as PlaybackQueue.handleNaturalFinish's
// automatic removal, instead of each reimplementing (or forgetting) it. Dynamic playlists are
// server-computed from rules with no editable membership, so they're skipped exactly like
// PlaybackQueue does.
enum PlaylistCleanup {
    // Best-effort, like PlaybackQueue.handleNaturalFinish's removal — a failed fetch/removal
    // shouldn't block the mark-played action itself. The next sync (or opening the playlist)
    // still shows the episode; the user can remove it by hand.
    static func removeFromManualPlaylists(
        episodeId: String, completed: Bool, playlistClient: PlaylistClient = PlaylistClient()
    ) async {
        guard completed, let playlists = try? await playlistClient.getPlaylists() else { return }
        for playlist in playlists
        where playlist.type == .manual && playlist.items.contains(where: { $0.episodeId == episodeId }) {
            try? await playlistClient.removeItem(playlistId: playlist.id, episodeId: episodeId)
        }
    }

    // Bulk counterpart for "mark all played" (#490/#569): a single fetch of every playlist, then
    // remove every item belonging to the show — scoped the same way DownloadCleanup.deleteAllEligible
    // is, since mark-all-played reaches the show's whole back catalogue server-side regardless of
    // how much of it is paged into the caller's own episode list.
    static func removeAllFromManualPlaylists(
        forShowId showId: String, playlistClient: PlaylistClient = PlaylistClient()
    ) async {
        guard let playlists = try? await playlistClient.getPlaylists() else { return }
        for playlist in playlists where playlist.type == .manual {
            for item in playlist.items where item.showId == showId {
                try? await playlistClient.removeItem(playlistId: playlist.id, episodeId: item.episodeId)
            }
        }
    }
}
