import Foundation

struct Subscription: Codable, Identifiable, Hashable {
    let id: String
    let userId: String
    let showId: String
    let showTitle: String
    let showAuthor: String
    let showArtworkUrl: String?
    let subscribedAt: Date
    // The publish date of this show's most recent episode, for the "Latest episode" sort mode
    // (#438). Nil on a row that predates the field on the API; sorted as oldest until the next
    // feed poll backfills it. decodeIfPresent so an older API response still decodes cleanly.
    let latestEpisodePublishedAt: Date?

    init(
        id: String, userId: String, showId: String, showTitle: String, showAuthor: String,
        showArtworkUrl: String?, subscribedAt: Date, latestEpisodePublishedAt: Date? = nil
    ) {
        self.id = id
        self.userId = userId
        self.showId = showId
        self.showTitle = showTitle
        self.showAuthor = showAuthor
        self.showArtworkUrl = showArtworkUrl
        self.subscribedAt = subscribedAt
        self.latestEpisodePublishedAt = latestEpisodePublishedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        userId = try container.decode(String.self, forKey: .userId)
        showId = try container.decode(String.self, forKey: .showId)
        showTitle = try container.decode(String.self, forKey: .showTitle)
        showAuthor = try container.decode(String.self, forKey: .showAuthor)
        showArtworkUrl = try container.decodeIfPresent(String.self, forKey: .showArtworkUrl)
        subscribedAt = try container.decode(Date.self, forKey: .subscribedAt)
        latestEpisodePublishedAt = try container.decodeIfPresent(Date.self, forKey: .latestEpisodePublishedAt)
    }
}
