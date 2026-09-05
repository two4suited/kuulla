import Foundation

// How the subscribed-shows list is ordered on Library and Subscriptions (#438). Mirrors the
// API's Kuulla.Api.Models.SubscriptionSortOrder enum, including its raw values, since the wire
// format is a plain integer. Title is 0 — the historical Library default — so a settings
// document that predates this field decodes as .title.
enum SubscriptionSortOrder: Int, Codable, CaseIterable, Identifiable {
    case title = 0
    case latestEpisode = 1
    case recentlyAdded = 2
    case manual = 3

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .title: "Title (A–Z)"
        case .latestEpisode: "Latest episode"
        case .recentlyAdded: "Recently added"
        case .manual: "Manual"
        }
    }
}
