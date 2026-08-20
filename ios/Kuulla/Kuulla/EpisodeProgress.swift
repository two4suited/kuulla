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
}
