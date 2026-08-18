import Foundation
import SwiftData

// SyncAdapter for EpisodeStateRecord, calling POST /api/sync/episodes
// (src/Kuulla.Api/Program.cs, reconciliation protocol documented in docs/sync-conventions.md).
struct EpisodeSyncAdapter: SyncAdapter {
    let domain = "episodes"

    private let apiClient: ApiClient

    init(apiClient: ApiClient = .shared) {
        self.apiClient = apiClient
    }

    func push(
        deviceId: String,
        lastSyncedAt: Date,
        localHash: String,
        dirtyRecords: [EpisodeStateRecord]
    ) async throws -> SyncPushResult<EpisodeStateRecord> {
        let changes = dirtyRecords.map {
            EpisodeStateChangeDTO(
                episodeId: $0.id,
                showId: $0.showId,
                positionSeconds: $0.positionSeconds,
                completed: $0.completed,
                updatedAt: $0.updatedAt)
        }
        let request = SyncEpisodesRequestDTO(
            deviceId: deviceId, lastSyncedAt: lastSyncedAt, localHash: localHash, changes: changes)

        let result: SyncEpisodesResultDTO = try await apiClient.post(["api", "sync", "episodes"], body: request)

        let serverChanges = result.serverChanges.map {
            EpisodeStateRecord(
                id: $0.episodeId,
                showId: $0.showId,
                positionSeconds: $0.positionSeconds,
                completed: $0.completed,
                updatedAt: $0.updatedAt)
        }
        return SyncPushResult(serverChanges: serverChanges, syncedAt: result.syncedAt, hash: result.hash)
    }

    func apply(_ record: EpisodeStateRecord, in context: ModelContext) throws {
        let id = record.id
        let existing = try context.fetch(FetchDescriptor<EpisodeStateRecord>(
            predicate: #Predicate { $0.id == id }
        )).first

        if let existing {
            // Last-write-wins: a serverChange can be an update from another device that predates
            // a not-yet-pushed local edit (e.g. still waiting on the debounce). Only overwrite —
            // and only clear isDirty — when the incoming record is actually newer, so a pending
            // local edit's dirty flag is never cleared without its value having actually landed.
            guard record.updatedAt > existing.updatedAt else { return }
            existing.showId = record.showId
            existing.positionSeconds = record.positionSeconds
            existing.completed = record.completed
            existing.updatedAt = record.updatedAt
            existing.isDirty = false
        } else {
            context.insert(record)
        }
    }
}

private struct EpisodeStateChangeDTO: Encodable {
    let episodeId: String
    let showId: String
    let positionSeconds: Int
    let completed: Bool
    let updatedAt: Date
}

private struct SyncEpisodesRequestDTO: Encodable {
    let deviceId: String
    let lastSyncedAt: Date
    let localHash: String
    let changes: [EpisodeStateChangeDTO]
}

private struct SyncEpisodesResultDTO: Decodable {
    let serverChanges: [EpisodeStateDTO]
    let syncedAt: Date
    let hash: String
}

// Mirrors src/Kuulla.Api/Models/EpisodeState.cs's wire shape.
private struct EpisodeStateDTO: Decodable {
    let episodeId: String
    let showId: String
    let positionSeconds: Int
    let completed: Bool
    let updatedAt: Date
}
