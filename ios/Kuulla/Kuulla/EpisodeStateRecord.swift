import Foundation
import SwiftData

// Local mirror of the API's EpisodeState (src/Kuulla.Api/Models/EpisodeState.cs) — the first
// consumer of SyncEngine/Syncable. `id` is the episode id, matching the server's convention of
// using it as the document id within a user's partition.
@Model
final class EpisodeStateRecord: Syncable {
    @Attribute(.unique) var id: String
    var showId: String
    var positionSeconds: Int
    var completed: Bool
    var updatedAt: Date
    var isDirty: Bool
    // True only when the unlistened-episode-limit enforcement job marked this episode played
    // rather than the user (#97) — lets the UI show "auto-marked played" with an undo.
    var autoPlayed: Bool
    // Server-computed by the auto-archive rule (#187); the client never sets this directly.
    // Archived episodes are hidden from the episode list, mirroring Web's ShowDetail filtering.
    // The `= false` default (not just the initializer's) lets SwiftData lightweight-migrate
    // existing on-device stores that predate this field.
    var archived: Bool = false
    // The device that last wrote this position server-side (EpisodeState.DeviceId), populated
    // from sync pulls — nil for records that predate this field or were only ever written
    // locally before a sync round-trip. The cross-device resume prompt (#241) uses it to tell
    // "another device moved this" from "this device did". Property-level default for lightweight
    // migration, same rationale as `archived`.
    var deviceId: String? = nil
    // The position (and wall-clock time) this device itself last played to. Updated only on this
    // device's own local playback writes and never overwritten by a sync pull, so the resume
    // prompt (#241) can still fall back to this device's own position when the user declines a
    // handoff from another device.
    var lastLocalPositionSeconds: Int = 0
    var lastLocalPlaybackAt: Date = Date.distantPast

    init(
        id: String,
        showId: String,
        positionSeconds: Int,
        completed: Bool,
        updatedAt: Date,
        isDirty: Bool = false,
        autoPlayed: Bool = false,
        archived: Bool = false,
        deviceId: String? = nil,
        lastLocalPositionSeconds: Int = 0,
        lastLocalPlaybackAt: Date = .distantPast
    ) {
        self.id = id
        self.showId = showId
        self.positionSeconds = positionSeconds
        self.completed = completed
        self.updatedAt = updatedAt
        self.isDirty = isDirty
        self.autoPlayed = autoPlayed
        self.archived = archived
        self.deviceId = deviceId
        self.lastLocalPositionSeconds = lastLocalPositionSeconds
        self.lastLocalPlaybackAt = lastLocalPlaybackAt
    }
}

struct EpisodeStateWriteResult: Sendable {
    let positionSeconds: Int
    let completed: Bool
    let updatedAt: Date
    let deviceId: String?
    let lastLocalPositionSeconds: Int
    let lastLocalPlaybackAt: Date
    let didPersist: Bool
    let transitionedToPlayed: Bool
}

// The one local episode-state write path for phone playback, queue auto-advance, and CarPlay.
// It detects the played transition inside the sync engine's actor-isolated context, then publishes
// every cross-surface effect only after the write has committed.
@MainActor
enum EpisodeStateCoordinator {
    private static var playlistRefreshRetryTask: Task<Void, Never>?

    static func persist(
        episodeId: String,
        showId: String,
        positionSeconds: Int,
        completed: Bool,
        preventCompletedDowngrade: Bool,
        catalogContext: ModelContext,
        episodeSyncEngine: SyncEngine<EpisodeSyncAdapter>,
        playlistSyncEngine: SyncEngine<PlaylistSyncAdapter>?,
        playlistClient: PlaylistClient = PlaylistClient()
    ) async throws -> EpisodeStateWriteResult {
        let updatedAt = Date()
        let result = try await episodeSyncEngine.writeReturning { context in
            let descriptor = FetchDescriptor<EpisodeStateRecord>(
                predicate: #Predicate { $0.id == episodeId })
            let existing = try context.fetch(descriptor).first

            if preventCompletedDowngrade, completed == false, existing?.completed == true {
                return EpisodeStateWriteResult(
                    positionSeconds: existing?.positionSeconds ?? positionSeconds,
                    completed: true,
                    updatedAt: existing?.updatedAt ?? updatedAt,
                    deviceId: existing?.deviceId,
                    lastLocalPositionSeconds: existing?.lastLocalPositionSeconds ?? 0,
                    lastLocalPlaybackAt: existing?.lastLocalPlaybackAt ?? .distantPast,
                    didPersist: false,
                    transitionedToPlayed: false)
            }

            let transitionedToPlayed = completed && existing?.completed != true
            if let existing {
                existing.showId = showId
                existing.positionSeconds = positionSeconds
                existing.completed = completed
                existing.updatedAt = updatedAt
                existing.autoPlayed = false
                existing.lastLocalPositionSeconds = positionSeconds
                existing.lastLocalPlaybackAt = updatedAt
                existing.isDirty = true
            } else {
                context.insert(EpisodeStateRecord(
                    id: episodeId,
                    showId: showId,
                    positionSeconds: positionSeconds,
                    completed: completed,
                    updatedAt: updatedAt,
                    isDirty: true,
                    lastLocalPositionSeconds: positionSeconds,
                    lastLocalPlaybackAt: updatedAt))
            }

            return EpisodeStateWriteResult(
                positionSeconds: positionSeconds,
                completed: completed,
                updatedAt: updatedAt,
                deviceId: existing?.deviceId,
                lastLocalPositionSeconds: positionSeconds,
                lastLocalPlaybackAt: updatedAt,
                didPersist: true,
                transitionedToPlayed: transitionedToPlayed)
        }

        guard result.didPersist else { return result }

        CatalogCache.recordEpisodeStateChange(
            episodeId: episodeId,
            showId: showId,
            completed: result.completed,
            positionSeconds: result.positionSeconds,
            in: catalogContext)

        guard result.transitionedToPlayed else { return result }

        await PlaylistCleanup.removeFromManualPlaylists(
            episodeId: episodeId,
            completed: true,
            playlistSyncEngine: playlistSyncEngine,
            playlistClient: playlistClient)

        // Dynamic playlists are server-computed. Push the episode transition first, then pull the
        // authoritative playlist membership instead of making a server-owned record dirty here.
        // If either domain is offline, keep one coalesced retry alive so a later successful
        // episode push is always followed by the playlist pull it makes authoritative.
        if await synchronizePlayedState(
            episodeSyncEngine: episodeSyncEngine,
            playlistSyncEngine: playlistSyncEngine
        ) {
            playlistRefreshRetryTask?.cancel()
            playlistRefreshRetryTask = nil
        } else {
            schedulePlaylistRefreshRetry(
                episodeSyncEngine: episodeSyncEngine,
                playlistSyncEngine: playlistSyncEngine)
        }

        return result
    }

    private static func synchronizePlayedState(
        episodeSyncEngine: SyncEngine<EpisodeSyncAdapter>,
        playlistSyncEngine: SyncEngine<PlaylistSyncAdapter>?
    ) async -> Bool {
        guard await episodeSyncEngine.syncNow() else { return false }
        guard let playlistSyncEngine else { return true }
        return await playlistSyncEngine.syncNow()
    }

    private static func schedulePlaylistRefreshRetry(
        episodeSyncEngine: SyncEngine<EpisodeSyncAdapter>,
        playlistSyncEngine: SyncEngine<PlaylistSyncAdapter>?
    ) {
        playlistRefreshRetryTask?.cancel()
        playlistRefreshRetryTask = Task {
            var delaySeconds = 5
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(delaySeconds))
                guard !Task.isCancelled else { return }
                if await synchronizePlayedState(
                    episodeSyncEngine: episodeSyncEngine,
                    playlistSyncEngine: playlistSyncEngine
                ) {
                    playlistRefreshRetryTask = nil
                    return
                }
                delaySeconds = min(delaySeconds * 2, 300)
            }
        }
    }
}
