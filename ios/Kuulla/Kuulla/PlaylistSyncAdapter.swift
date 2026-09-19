import Foundation
import SwiftData

// SyncAdapter for PlaylistRecord, calling POST /api/sync/playlists
// (src/Kuulla.Api/Program.cs, reconciliation protocol documented in docs/sync-conventions.md).
// Mirrors EpisodeSyncAdapter.swift's structure.
struct PlaylistSyncAdapter: SyncAdapter {
    let domain = "playlists"

    private let apiClient: ApiClient
    private let autoDownloadHandler: PlaylistAutoDownloadHandler

    init(
        apiClient: ApiClient = .shared,
        enqueueAutoDownloads: @escaping ([PlaylistItemRecord], ModelContext) -> Void =
            PlaylistAutoDownload.enqueue
    ) {
        self.apiClient = apiClient
        self.autoDownloadHandler = PlaylistAutoDownloadHandler(enqueueAutoDownloads)
    }

    func push(
        deviceId: String,
        lastSyncedAt: Date,
        localHash: String,
        dirtyRecords: [PlaylistRecord]
    ) async throws -> SyncPushResult<PlaylistRecord> {
        let changes = dirtyRecords.map {
            PlaylistChangeDTO(
                id: $0.id,
                name: $0.name,
                type: $0.type,
                items: $0.items,
                createdAt: $0.createdAt,
                updatedAt: $0.updatedAt,
                dynamicConfig: $0.dynamicConfig,
                icon: $0.icon,
                accentColor: $0.accentColor,
                playNextBehavior: $0.playNextBehavior,
                autoDownload: $0.autoDownload)
        }
        let request = SyncPlaylistsRequestDTO(
            deviceId: deviceId, lastSyncedAt: lastSyncedAt, localHash: localHash, changes: changes)

        let result: SyncPlaylistsResultDTO = try await apiClient.post(["api", "sync", "playlists"], body: request)

        let serverChanges = result.serverChanges.map {
            PlaylistRecord(
                id: $0.id,
                name: $0.name,
                type: $0.type,
                items: $0.items,
                createdAt: $0.createdAt,
                updatedAt: $0.updatedAt,
                dynamicConfig: $0.dynamicConfig,
                icon: $0.icon,
                accentColor: $0.accentColor,
                playNextBehavior: $0.playNextBehavior,
                autoDownload: $0.autoDownload ?? false,
                deleted: $0.deleted ?? false)
        }
        return SyncPushResult(serverChanges: serverChanges, syncedAt: result.syncedAt, hash: result.hash)
    }

    func apply(_ record: PlaylistRecord, in context: ModelContext) throws {
        let id = record.id
        let existing = try context.fetch(FetchDescriptor<PlaylistRecord>(
            predicate: #Predicate { $0.id == id }
        )).first

        if record.deleted {
            // Tombstone (#400): the playlist was deleted on another device. Remove the local row
            // outright rather than keeping a soft-deleted copy — nothing on iOS reads `deleted`,
            // and the server keeps the tombstone until it GC's it, so a re-push can't resurrect
            // it. No isDirty guard: a local edit racing the delete loses (tombstone wins), matching
            // the server-side reconciler.
            if let existing {
                context.delete(existing)
            }
            return
        }

        if let existing {
            // Last-write-wins, matching EpisodeSyncAdapter.apply — only overwrite (and only clear
            // isDirty) when the incoming record is actually newer than what's stored locally.
            guard record.updatedAt > existing.updatedAt else { return }
            let existingEpisodeIds = Set(existing.items.map(\.episodeId))
            let newItems = record.autoDownload
                ? record.items.filter { !existingEpisodeIds.contains($0.episodeId) }
                : []
            existing.name = record.name
            existing.type = record.type
            existing.items = record.items
            existing.updatedAt = record.updatedAt
            existing.dynamicConfig = record.dynamicConfig
            existing.icon = record.icon
            existing.accentColor = record.accentColor
            existing.playNextBehavior = record.playNextBehavior
            existing.autoDownload = record.autoDownload
            existing.isDirty = false
            if !newItems.isEmpty {
                autoDownloadHandler.enqueue(newItems, in: context)
            }
        } else {
            context.insert(record)
        }
    }

    func didCompleteSync(in context: ModelContext) throws {
        PlaylistAutoDownload.retryPending(in: context)
    }
}

private final class PlaylistAutoDownloadHandler: @unchecked Sendable {
    private let action: ([PlaylistItemRecord], ModelContext) -> Void

    init(_ action: @escaping ([PlaylistItemRecord], ModelContext) -> Void) {
        self.action = action
    }

    func enqueue(_ items: [PlaylistItemRecord], in context: ModelContext) {
        action(items, context)
    }
}

enum PlaylistAutoDownload {
    static func enqueue(_ items: [PlaylistItemRecord], in context: ModelContext) {
        let statuses = DownloadStatus.statusMap(for: Set(items.map(\.episodeId)), in: context)
        let pendingRecords = (try? context.fetch(FetchDescriptor<PendingPlaylistDownloadRecord>())) ?? []
        var pendingByEpisodeId = Dictionary(uniqueKeysWithValues: pendingRecords.map { ($0.id, $0) })

        for item in items {
            if statuses[item.episodeId] == .complete {
                if let pending = pendingByEpisodeId.removeValue(forKey: item.episodeId) {
                    context.delete(pending)
                }
                continue
            }
            if statuses[item.episodeId] == .downloading {
                continue
            }

            if pendingByEpisodeId[item.episodeId] == nil {
                let pending = PendingPlaylistDownloadRecord(id: item.episodeId, showId: item.showId)
                context.insert(pending)
                pendingByEpisodeId[item.episodeId] = pending
            }

            if let episode = CatalogCache.episode(showId: item.showId, episodeId: item.episodeId, in: context) {
                start(episode, pendingEpisodeId: item.episodeId, container: context.container)
                continue
            }

            let container = context.container
            Task {
                guard let episode = try? await PodcastCatalogClient().getEpisode(
                    showId: item.showId, episodeId: item.episodeId)
                else { return }
                start(episode, pendingEpisodeId: item.episodeId, container: container)
            }
        }
    }

    static func retryPending(in context: ModelContext) {
        let pending = (try? context.fetch(FetchDescriptor<PendingPlaylistDownloadRecord>())) ?? []
        enqueue(
            pending.map {
                PlaylistItemRecord(episodeId: $0.id, showId: $0.showId, addedAt: $0.createdAt, order: "")
            },
            in: context)
    }

    private static func start(
        _ episode: Episode, pendingEpisodeId: String, container: ModelContainer
    ) {
        DispatchQueue.main.async {
            guard DownloadManager.shared.startDownload(episode: episode) else { return }

            let context = ModelContext(container)
            guard let pending = try? context.fetch(FetchDescriptor<PendingPlaylistDownloadRecord>(
                predicate: #Predicate { $0.id == pendingEpisodeId }
            )).first else { return }
            context.delete(pending)
            try? context.save()
        }
    }
}

private struct PlaylistChangeDTO: Encodable {
    let id: String
    let name: String
    let type: PlaylistType
    let items: [PlaylistItemRecord]
    let createdAt: Date
    let updatedAt: Date
    let dynamicConfig: DynamicPlaylistConfigRecord?
    let icon: String?
    let accentColor: String?
    let playNextBehavior: PlayNextBehavior?
    let autoDownload: Bool
}

private struct SyncPlaylistsRequestDTO: Encodable {
    let deviceId: String
    let lastSyncedAt: Date
    let localHash: String
    let changes: [PlaylistChangeDTO]
}

private struct SyncPlaylistsResultDTO: Decodable {
    let serverChanges: [PlaylistSyncDTO]
    let syncedAt: Date
    let hash: String
}

// Mirrors src/Kuulla.Api/Models/Playlist.cs's wire shape (sync response entries) — distinct from
// PlaylistClient.swift's `Playlist` (which also carries `userId`, irrelevant here since the sync
// response is always scoped to the authenticated user already).
private struct PlaylistSyncDTO: Decodable {
    let id: String
    let name: String
    let type: PlaylistType
    let items: [PlaylistItemRecord]
    let createdAt: Date
    let updatedAt: Date
    let dynamicConfig: DynamicPlaylistConfigRecord?
    let icon: String?
    let accentColor: String?
    let playNextBehavior: PlayNextBehavior?
    let autoDownload: Bool?
    // #400 — present and true when this entry is a tombstone for a playlist deleted elsewhere.
    // Optional for forward/backward compatibility with a server that omits it.
    let deleted: Bool?
}
