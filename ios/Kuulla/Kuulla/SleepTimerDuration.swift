import Foundation

// Preset minutes offered in the sleep timer picker (#208). The underlying setting is a plain
// Int (minutes) rather than this enum — these are just the commonly-useful presets, mirroring
// how PlaybackSpeedOption/AutoSkipDuration expose a fixed set of options rather than free-form
// numeric entry.
enum SleepTimerDuration: Int, CaseIterable, Identifiable {
    case five = 5
    case ten = 10
    case fifteen = 15
    case thirty = 30
    case fortyFive = 45
    case sixty = 60
    case ninety = 90

    var id: Int { rawValue }

    var label: String { "\(rawValue) min" }
}
