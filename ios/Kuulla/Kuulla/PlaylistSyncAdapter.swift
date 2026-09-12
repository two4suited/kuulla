import Foundation
import SwiftData

// SyncAdapter for PlaylistRecord, calling POST /api/sync/playlists
// (src/Kuulla.Api/Program.cs, reconciliation protocol documented in docs/sync-conventions.md).
// Mirrors EpisodeSyncAdapter.swift's structure.
struct PlaylistSyncAdapter: SyncAdapter {
    let domain = "playlists"

    private let apiClient: ApiClient

    init(apiClient: ApiClient = .shared) {
        self.apiClient = apiClient
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
                accentColor: $0.accentColor)
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
            existing.name = record.name
            existing.type = record.type
            existing.items = record.items
            existing.updatedAt = record.updatedAt
            existing.dynamicConfig = record.dynamicConfig
            existing.icon = record.icon
            existing.accentColor = record.accentColor
            existing.isDirty = false
        } else {
            context.insert(record)
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
    // #400 — present and true when this entry is a tombstone for a playlist deleted elsewhere.
    // Optional for forward/backward compatibility with a server that omits it.
    let deleted: Bool?
}
