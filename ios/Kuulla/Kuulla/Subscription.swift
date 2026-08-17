import Foundation

struct Subscription: Codable, Identifiable, Hashable {
    let id: String
    let userId: String
    let showId: String
    let showTitle: String
    let showAuthor: String
    let showArtworkUrl: String?
    let subscribedAt: Date
}
