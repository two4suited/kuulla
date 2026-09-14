import Foundation

// Common gain presets surfaced in the volume offset picker (#708). The underlying setting is a
// plain Float in dB (-12...12, validated API-side) rather than this enum — these are just the
// commonly-useful presets, mirroring PlaybackSpeedOption's rationale.
enum VolumeOffsetOption: Float, CaseIterable, Identifiable {
    case down12 = -12
    case down9 = -9
    case down6 = -6
    case down3 = -3
    case off = 0
    case up3 = 3
    case up6 = 6
    case up9 = 9
    case up12 = 12

    var id: Float { rawValue }

    var label: String {
        rawValue == 0
            ? "Off"
            : "\(rawValue > 0 ? "+" : "")\(rawValue.formatted(.number.precision(.fractionLength(0...1)))) dB"
    }
}
