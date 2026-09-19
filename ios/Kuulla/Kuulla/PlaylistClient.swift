import Foundation
import Observation
import SwiftData

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

    // PUT /api/playlists/{id} sets the playlist's full editable state — pass the current
    // icon/accentColor/playNextBehavior when only the name changes, or they'll be cleared.
    func renamePlaylist(
        id: String, name: String, icon: String? = nil, accentColor: String? = nil,
        playNextBehavior: PlayNextBehavior? = nil, autoDownload: Bool? = nil
    ) async throws -> Playlist? {
        do {
            return try await apiClient.put(
                ["api", "playlists", id],
                body: RenamePlaylistRequest(
                    name: name, icon: icon, accentColor: accentColor,
                    playNextBehavior: playNextBehavior, autoDownload: autoDownload))
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
    var playNextBehavior: PlayNextBehavior?
    var autoDownload: Bool?
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
    // Per-playlist play-next override (#629); nil inherits. var so the edit sheet can reflect a
    // change in place, like `name`.
    var playNextBehavior: PlayNextBehavior?
    var autoDownload: Bool?
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
    let playNextBehavior: PlayNextBehavior?
    let autoDownload: Bool?
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
    // Local-first (#771): edits every containing manual PlaylistRecord through
    // playlistSyncEngine.write *before* touching the network, mirroring
    // PlaylistsView.deleteLocalRecord's reasoning — every local reader (Playlists tab counts, the
    // PlaylistDetailView placeholder, CarPlay's cache-first lists, PlaybackQueue) reads that store
    // directly and would otherwise stay stale until the next sync pull. The local edit always marks
    // the record dirty (not just on a failed DELETE below) — every other local mutation in this
    // codebase does the same (see ShowDetailView.toggleCompleted) because PlaylistSyncAdapter.apply
    // only accepts an incoming server record when its updatedAt is newer than what's stored
    // locally; leaving updatedAt untouched here would let a sync pull that races the DELETE below
    // silently overwrite this removal with stale (pre-removal) server state. The DELETE is then
    // just the fast path to reflect the removal on the server quickly instead of waiting for the
    // next debounced push. Server discovery is merged with local removals so a playlist that is
    // present only on the server is still cleaned up when the local sync store is incomplete.
    static func removeFromManualPlaylists(
        episodeId: String, completed: Bool,
        playlistSyncEngine: SyncEngine<PlaylistSyncAdapter>?,
        playlistClient: PlaylistClient = PlaylistClient()
    ) async {
        guard completed else { return }
        let localRemovals: [Removal] = if let playlistSyncEngine {
            await removeItemsLocally(playlistSyncEngine: playlistSyncEngine) { $0.episodeId == episodeId }
        } else {
            []
        }
        let serverRemovals = await findServerRemovals(playlistClient: playlistClient) {
            $0.episodeId == episodeId
        }
        await pushRemovals(
            mergeRemovals(localRemovals, serverRemovals), playlistClient: playlistClient)
    }

    // Bulk counterpart for "mark all played" (#490/#569): scoped the same way
    // DownloadCleanup.deleteAllEligible is, since mark-all-played reaches the show's whole back
    // catalogue server-side regardless of how much of it is paged into the caller's own episode
    // list. Same local-first shape as removeFromManualPlaylists above.
    static func removeAllFromManualPlaylists(
        forShowId showId: String,
        playlistSyncEngine: SyncEngine<PlaylistSyncAdapter>?,
        playlistClient: PlaylistClient = PlaylistClient()
    ) async {
        let localRemovals: [Removal] = if let playlistSyncEngine {
            await removeItemsLocally(playlistSyncEngine: playlistSyncEngine) { $0.showId == showId }
        } else {
            []
        }
        let serverRemovals = await findServerRemovals(playlistClient: playlistClient) {
            $0.showId == showId
        }
        await pushRemovals(
            mergeRemovals(localRemovals, serverRemovals), playlistClient: playlistClient)
    }

    private struct Removal: Hashable {
        let playlistId: String
        let episodeId: String
    }

    // Removes every item matching `matches` from every local manual PlaylistRecord in one
    // SyncEngine write, and returns the (playlistId, episodeId) pairs actually removed so the
    // caller can also try the server-side DELETE for each. Dynamic playlists are skipped — they're
    // server-computed from rules with no editable membership, matching PlaybackQueue's own
    // automatic-removal carve-out.
    private static func removeItemsLocally(
        playlistSyncEngine: SyncEngine<PlaylistSyncAdapter>,
        matching matches: @escaping (PlaylistItemRecord) -> Bool
    ) async -> [Removal] {
        var removed: [Removal] = []
        try? await playlistSyncEngine.write { context in
            let records = try context.fetch(FetchDescriptor<PlaylistRecord>())
            for record in records where record.type == .manual && !record.deleted {
                let matchedIds = record.items.filter(matches).map(\.episodeId)
                guard !matchedIds.isEmpty else { continue }
                record.items.removeAll(where: matches)
                record.updatedAt = Date()
                record.isDirty = true
                removed.append(contentsOf: matchedIds.map { Removal(playlistId: record.id, episodeId: $0) })
            }
        }
        if !removed.isEmpty {
            await MainActor.run {
                PlaylistChangeSignal.shared.bump()
            }
        }
        return removed
    }

    // A playlist can be visible from a direct REST fetch before its first sync pull has created a
    // local PlaylistRecord (for example immediately after it was created on another device).
    // Discover server-side matches on every cleanup so incomplete local state cannot leave an
    // episode behind in a playlist that has not been synced to this device.
    private static func findServerRemovals(
        playlistClient: PlaylistClient,
        matching matches: (PlaylistItemRecord) -> Bool
    ) async -> [Removal] {
        guard let playlists = try? await playlistClient.getPlaylists() else { return [] }
        return playlists
            .filter { $0.type == .manual }
            .flatMap { playlist in
                playlist.items
                    .filter(matches)
                    .map { Removal(playlistId: playlist.id, episodeId: $0.episodeId) }
            }
    }

    private static func mergeRemovals(_ local: [Removal], _ server: [Removal]) -> [Removal] {
        var seen = Set<Removal>()
        return (local + server).filter { seen.insert($0).inserted }
    }

    // Best-effort, like the old implementation — a failed DELETE shouldn't block the mark-played
    // action itself. The local records above are already marked dirty regardless of these calls'
    // outcome, so a failure here just means that removal waits for the sync engine's own debounced
    // push instead of reaching the server immediately. Fanned out concurrently since each pair is
    // an independent DELETE to a (possibly) different playlist — "mark all played" can touch
    // several playlists at once, and there's no reason to serialize those round trips.
    private static func pushRemovals(
        _ pairs: [Removal], playlistClient: PlaylistClient
    ) async {
        await withTaskGroup(of: Void.self) { group in
            for pair in pairs {
                group.addTask {
                    try? await playlistClient.removeItem(playlistId: pair.playlistId, episodeId: pair.episodeId)
                }
            }
        }
    }
}

// Notifies playlist views that a local cleanup changed an embedded PlaylistRecord. SwiftData
// contexts owned by SwiftUI views do not reliably observe saves made through SyncEngine's context,
// so the signal provides an explicit repaint hook for screens that are already visible.
@MainActor
@Observable
final class PlaylistChangeSignal {
    static let shared = PlaylistChangeSignal()
    private init() {}

    private(set) var version = 0

    func bump() {
        version += 1
    }
}
