import Foundation

// Common speed presets surfaced in the playback speed picker. The underlying setting is a plain
// Float (0.5...3.0 in 0.1 increments, validated API-side) rather than this enum — these are just
// the commonly-useful presets, mirroring how AutoSkipDuration exposes a fixed set of options
// rather than free-form numeric entry.
enum PlaybackSpeedOption: Float, CaseIterable, Identifiable {
    case half = 0.5
    case threeQuarters = 0.75
    case normal = 1.0
    case oneQuarter = 1.25
    case oneAndAHalf = 1.5
    case oneThreeQuarters = 1.75
    case double = 2.0
    case twoAndAHalf = 2.5
    case triple = 3.0

    var id: Float { rawValue }

    var label: String { "\(rawValue.formatted(.number.precision(.fractionLength(0...2))))x" }
}
