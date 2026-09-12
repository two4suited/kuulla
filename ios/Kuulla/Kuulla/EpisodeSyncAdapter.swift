import Foundation
import SwiftData

// SyncAdapter for EpisodeStateRecord, calling POST /api/sync/episodes
// (src/Kuulla.Api/Program.cs, reconciliation protocol documented in docs/sync-conventions.md).
struct EpisodeSyncAdapter: nonisolated SyncAdapter {
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
                updatedAt: $0.updatedAt,
                autoPlayed: $0.autoPlayed,
                archived: $0.archived,
                deviceId: $0.deviceId)
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
            existing.autoPlayed = record.autoPlayed
            existing.archived = record.archived
            existing.deviceId = record.deviceId
            // lastLocalPositionSeconds / lastLocalPlaybackAt are deliberately left untouched —
            // they track what *this* device played and must survive a pull that carries another
            // device's newer position (#241).
            existing.isDirty = false
        } else {
            context.insert(record)
        }
    }
}

extension SyncEngine where Adapter == EpisodeSyncAdapter {
    // Clears completed/autoPlayed and resets position to zero on the local record and marks it
    // dirty for the next sync push — the undo for an unlistened-episode-limit auto-mark (#97/#100).
    // The server never trusts a client-supplied autoPlayed value (EpisodeStateChange carries no such
    // field), so any push resulting from this — like any other user-initiated write — always lands
    // as autoPlayed=false.
    // Returns the post-write record (nil if there was no local record for this episode) so callers
    // can update their own UI state directly from it rather than re-fetching through their own
    // ModelContext, which — same hazard EpisodeDetailView.persist() works around — isn't
    // guaranteed to observe a write made through this engine's own context synchronously.
    @discardableResult
    func restoreAutoPlayed(episodeId: String) async -> EpisodeStateRecord? {
        var restored: EpisodeStateRecord?
        do {
            try await write { context in
                let descriptor = FetchDescriptor<EpisodeStateRecord>(predicate: #Predicate { $0.id == episodeId })
                guard let existing = try context.fetch(descriptor).first else { return }
                existing.completed = false
                existing.autoPlayed = false
                existing.archived = false
                existing.positionSeconds = 0
                existing.updatedAt = Date()
                existing.isDirty = true
                restored = EpisodeStateRecord(
                    id: existing.id, showId: existing.showId, positionSeconds: existing.positionSeconds,
                    completed: existing.completed, updatedAt: existing.updatedAt, isDirty: existing.isDirty,
                    autoPlayed: existing.autoPlayed, archived: existing.archived, deviceId: existing.deviceId,
                    lastLocalPositionSeconds: existing.lastLocalPositionSeconds,
                    lastLocalPlaybackAt: existing.lastLocalPlaybackAt)
            }
        } catch {
            assertionFailure("Failed to restore auto-played episode \(episodeId): \(error)")
        }
        return restored
    }

    // A detached snapshot of one episode's state read through the engine's own ModelContext —
    // the one server pulls are applied to. A caller that just awaited syncNow() and then read
    // back through its own @Environment(\.modelContext) instead can observe stale state (two
    // ModelContext instances over the same store aren't guaranteed to see each other's saves
    // immediately). Returns a plain copy, not the context-bound model, so it's safe to hold on
    // the main actor. Nil when there's no local record for this episode.
    func currentState(episodeId: String) async -> EpisodeStateRecord? {
        await read { context in
            let descriptor = FetchDescriptor<EpisodeStateRecord>(predicate: #Predicate { $0.id == episodeId })
            guard let existing = try? context.fetch(descriptor).first else { return nil }
            return EpisodeStateRecord(
                id: existing.id, showId: existing.showId, positionSeconds: existing.positionSeconds,
                completed: existing.completed, updatedAt: existing.updatedAt, isDirty: existing.isDirty,
                autoPlayed: existing.autoPlayed, archived: existing.archived, deviceId: existing.deviceId,
                lastLocalPositionSeconds: existing.lastLocalPositionSeconds,
                lastLocalPlaybackAt: existing.lastLocalPlaybackAt)
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
    let autoPlayed: Bool
    let archived: Bool
    let deviceId: String?

    private enum CodingKeys: String, CodingKey {
        case episodeId, showId, positionSeconds, completed, updatedAt, autoPlayed, archived, deviceId
    }

    // Defaults to false when absent so a server response that predates #100's/#187's field
    // additions still decodes cleanly rather than failing the whole sync.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        episodeId = try container.decode(String.self, forKey: .episodeId)
        showId = try container.decode(String.self, forKey: .showId)
        positionSeconds = try container.decode(Int.self, forKey: .positionSeconds)
        completed = try container.decode(Bool.self, forKey: .completed)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        autoPlayed = try container.decodeIfPresent(Bool.self, forKey: .autoPlayed) ?? false
        archived = try container.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        deviceId = try container.decodeIfPresent(String.self, forKey: .deviceId)
    }
}
