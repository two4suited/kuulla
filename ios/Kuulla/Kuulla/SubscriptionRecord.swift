import Foundation
import SwiftData

// On-device cache of one `Subscription` from GET /api/subscriptions. This is a plain
// read-through cache, not a `Syncable` sync domain — the server has no
// POST /api/sync/subscriptions endpoint, and the client only ever reads the list (subscribe/
// unsubscribe go through their own REST calls, which also update this store directly). See
// CatalogCache for the read/write helpers and CatalogRefreshService for when it's refilled.
@Model
final class SubscriptionRecord {
    @Attribute(.unique) var id: String
    var userId: String
    var showId: String
    var showTitle: String
    var showAuthor: String
    var showArtworkUrl: String?
    var subscribedAt: Date
    var latestEpisodePublishedAt: Date?
    var cachedAt: Date

    init(
        id: String,
        userId: String,
        showId: String,
        showTitle: String,
        showAuthor: String,
        showArtworkUrl: String?,
        subscribedAt: Date,
        latestEpisodePublishedAt: Date?,
        cachedAt: Date = .now
    ) {
        self.id = id
        self.userId = userId
        self.showId = showId
        self.showTitle = showTitle
        self.showAuthor = showAuthor
        self.showArtworkUrl = showArtworkUrl
        self.subscribedAt = subscribedAt
        self.latestEpisodePublishedAt = latestEpisodePublishedAt
        self.cachedAt = cachedAt
    }

    convenience init(from subscription: Subscription, cachedAt: Date = .now) {
        self.init(
            id: subscription.id,
            userId: subscription.userId,
            showId: subscription.showId,
            showTitle: subscription.showTitle,
            showAuthor: subscription.showAuthor,
            showArtworkUrl: subscription.showArtworkUrl,
            subscribedAt: subscription.subscribedAt,
            latestEpisodePublishedAt: subscription.latestEpisodePublishedAt,
            cachedAt: cachedAt)
    }

    var subscription: Subscription {
        Subscription(
            id: id,
            userId: userId,
            showId: showId,
            showTitle: showTitle,
            showAuthor: showAuthor,
            showArtworkUrl: showArtworkUrl,
            subscribedAt: subscribedAt,
            latestEpisodePublishedAt: latestEpisodePublishedAt)
    }
}
