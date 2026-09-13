import Foundation

enum EpisodeFormatting {
    static func formatDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = Int(duration.rounded())
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    // Friendly "3h 42m" / "42m" style, distinct from formatDuration's colon-separated player-time
    // style above — used for stats/totals (e.g. SettingsView's lifetime silence-trim time-saved
    // counter, #680) where a duration is being read as a quantity, not a scrubber position.
    // Rounds down to the minute — a running total measured in seconds would otherwise present as
    // false precision here.
    static func formatFriendlyDuration(_ duration: TimeInterval) -> String {
        let totalMinutes = Int(duration / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }
}
