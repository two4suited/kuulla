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
