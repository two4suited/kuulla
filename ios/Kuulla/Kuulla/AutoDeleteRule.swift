import Foundation

// When to delete a downloaded episode's local file. Mirrors the API's
// Kuulla.Api.Models.AutoDeleteRule enum, including its raw values, since the wire format is a
// plain integer. Never is the safe, non-destructive default — silently deleting a file the user
// downloaded on purpose without opt-in would be a surprising, hard-to-undo action.
enum AutoDeleteRule: Int, Codable, CaseIterable, Identifiable {
    case never = 0
    case afterPlayed = 1
    case afterDays = 2

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .never: "Never"
        case .afterPlayed: "After played"
        case .afterDays: "After days"
        }
    }
}
