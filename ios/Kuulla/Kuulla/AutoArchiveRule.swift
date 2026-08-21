import Foundation

// When to auto-archive a played episode (hide it from the active episode list). Mirrors the
// API's Kuulla.Api.Models.AutoArchiveRule enum, including its raw values, since the wire format
// is a plain integer. Never is the safe, non-destructive default.
enum AutoArchiveRule: Int, Codable, CaseIterable, Identifiable {
    case never = 0
    case afterPlayed = 1
    case after1Day = 2
    case after7Days = 3
    case after30Days = 4

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .never: "Never"
        case .afterPlayed: "Immediately after played"
        case .after1Day: "1 day after played"
        case .after7Days: "7 days after played"
        case .after30Days: "30 days after played"
        }
    }
}
