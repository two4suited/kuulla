import Foundation

// Preset seconds offered in the auto-skip intro/outro pickers. The underlying setting is a
// plain Int (seconds) rather than this enum — these are just the commonly-useful presets
// surfaced in the UI, mirroring how UnlistenedEpisodeCount/AutoArchiveRule expose a fixed set of
// options rather than free-form numeric entry.
enum AutoSkipDuration: Int, CaseIterable, Identifiable {
    case off = 0
    case five = 5
    case ten = 10
    case fifteen = 15
    case twenty = 20
    case thirty = 30
    case fortyFive = 45
    case sixty = 60

    var id: Int { rawValue }

    var label: String {
        self == .off ? "Off" : "\(rawValue)s"
    }
}
