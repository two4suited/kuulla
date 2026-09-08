import SwiftUI

// Controls how large show artwork tiles render in the Library and Subscriptions grids. Device-local
// (see LocalSettings) — how big you want the grid on your phone says nothing about your other
// devices, so this never round-trips through UserSettings. `.large` matches the layout that
// shipped before this option existed.
enum ShowIconSize: String, CaseIterable, Identifiable {
    case small
    case medium
    case large

    static let storageKey = "showIconSize"
    static let `default` = ShowIconSize.large

    var id: String { rawValue }

    var label: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        }
    }

    // Minimum width fed to GridItem(.adaptive(minimum:)). `.large` keeps the original 110pt value.
    var gridMinimum: Double {
        switch self {
        case .small: return 74
        case .medium: return 92
        case .large: return 110
        }
    }

    var systemImage: String {
        switch self {
        case .small: return "square.grid.4x3.fill"
        case .medium: return "square.grid.3x3.fill"
        case .large: return "square.grid.2x2.fill"
        }
    }

    // Resolves a stored @AppStorage string back to a case, tolerating a missing or stale value.
    static func current(_ raw: String) -> ShowIconSize {
        ShowIconSize(rawValue: raw) ?? .default
    }
}
