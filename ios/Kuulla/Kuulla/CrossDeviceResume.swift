import Foundation

// Decides whether opening an episode should offer "continue from where you left off on your
// other device" (#241). Pure so the branch logic is unit-testable without a ModelContext, the
// sync engine, or a running player — mirrors EpisodeDetailView.resolvedPlaybackURL's pattern.
enum CrossDeviceResume {
    struct Prompt: Equatable {
        // Where the other device left off — what "Resume" seeks to.
        let otherDevicePositionSeconds: Int
        // This device's own last position — what "Not now" falls back to.
        let localPositionSeconds: Int
    }

    // Minimum gap between the synced position and this device's own last position before the
    // prompt is worth showing. Below this the two devices are effectively in the same spot and a
    // prompt would just be noise.
    static let minimumDeltaSeconds = 15

    static func prompt(
        syncedPositionSeconds: Int,
        syncedUpdatedAt: Date,
        syncedDeviceId: String?,
        completed: Bool,
        currentDeviceId: String,
        lastLocalPositionSeconds: Int,
        lastLocalPlaybackAt: Date
    ) -> Prompt? {
        // A finished episode has nothing to resume — opening it is a deliberate replay.
        guard !completed else { return nil }

        // Only prompt when the synced position was last written by a *different* device. A nil
        // deviceId means the position has never round-tripped through sync (e.g. this device's
        // own not-yet-pushed write), so it can't be attributed to another device.
        guard let syncedDeviceId, syncedDeviceId != currentDeviceId else { return nil }

        // The other device's write has to be newer than anything this device played, otherwise
        // this device's local position is the more recent truth and there's nothing to hand off.
        guard syncedUpdatedAt > lastLocalPlaybackAt else { return nil }

        let delta = abs(syncedPositionSeconds - lastLocalPositionSeconds)
        guard delta >= minimumDeltaSeconds else { return nil }

        return Prompt(
            otherDevicePositionSeconds: syncedPositionSeconds,
            localPositionSeconds: lastLocalPositionSeconds)
    }
}

// Decides whether an in-progress playback session should surface the non-disruptive "now playing
// on another device" banner (#242) — e.g. the user pressed play on another device mid-episode.
// Never seeks on its own; the banner just offers the jump. Pure, same rationale as CrossDeviceResume.
enum CrossDeviceHandoff {
    struct Banner: Equatable {
        // Where the other device is — what tapping the banner seeks to.
        let targetPositionSeconds: Int
        // The synced record's UpdatedAt that produced this banner, so the view can remember it
        // was already surfaced and not re-raise the banner for the same remote write.
        let sourceUpdatedAt: Date
    }

    // Same "close enough to be noise" floor as the resume prompt.
    static let minimumDeltaSeconds = CrossDeviceResume.minimumDeltaSeconds

    static func banner(
        syncedPositionSeconds: Int,
        syncedUpdatedAt: Date,
        syncedDeviceId: String?,
        completed: Bool,
        currentDeviceId: String,
        currentPlaybackPositionSeconds: Int,
        lastSurfacedUpdatedAt: Date?
    ) -> Banner? {
        guard !completed else { return nil }

        // Only when the last server write came from a different device — our own position pushes
        // stamp this device's id, so a match means there's nothing to hand off.
        guard let syncedDeviceId, syncedDeviceId != currentDeviceId else { return nil }

        // Already showed (or dismissed) a banner for this remote write — don't nag on every poll.
        if let lastSurfacedUpdatedAt, syncedUpdatedAt <= lastSurfacedUpdatedAt { return nil }

        let delta = abs(syncedPositionSeconds - currentPlaybackPositionSeconds)
        guard delta >= minimumDeltaSeconds else { return nil }

        return Banner(targetPositionSeconds: syncedPositionSeconds, sourceUpdatedAt: syncedUpdatedAt)
    }
}
