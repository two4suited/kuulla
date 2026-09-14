import Foundation

// Pure playback-progress math backing ShowDetailView's progress bar — no duration is stored
// alongside EpisodeStateRecord.positionSeconds, so this combines it with Episode.duration
// (mirrors the Web implementation's ProgressPercent).
enum EpisodeProgress {
    static func fraction(positionSeconds: Int, duration: TimeInterval?) -> Double? {
        guard positionSeconds > 0, let duration, duration > 0 else {
            return nil
        }

        let value = Double(positionSeconds) / duration
        // Clamped away from the extremes so a fully-played (but not yet marked completed) episode
        // doesn't render a visually "full" bar, and a just-started one is still visible.
        return min(max(value, 0.01), 0.99)
    }

    // How close to the end (in seconds) playback has to be before it's treated as finished
    // (#704) — trailing outro/credits/silence a listener doesn't sit through all the way
    // shouldn't leave an episode stuck "in progress" forever, mirroring AntennaPod/Podcast
    // Addict's smart mark-as-played behavior.
    static let nearEndThresholdSeconds = 30

    // Pulled out as a pure function, mirroring AudioPlayer.shouldTriggerOutroSkip's own
    // threshold-crossing shape (including its "threshold longer than the episode itself is
    // misconfiguration, never fires" guard), so the boundary is unit-testable without a real
    // player. Without that guard, an episode no longer than the threshold (e.g. a short trailer)
    // would be marked completed within its first second of playback, since its entire runtime
    // already counts as "near the end". Duration not yet known (nil or <= 0) never counts as
    // near the end.
    static func isNearEnd(positionSeconds: Int, duration: TimeInterval?, thresholdSeconds: Int) -> Bool {
        guard thresholdSeconds > 0, let duration, duration > Double(thresholdSeconds) else { return false }
        return duration - Double(positionSeconds) <= Double(thresholdSeconds)
    }
}
