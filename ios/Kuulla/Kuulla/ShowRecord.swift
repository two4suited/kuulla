import Foundation
import SwiftData

// On-device cache of one `Show` from GET /api/shows/{id}. Read-through cache (see
// SubscriptionRecord's note); lets ShowDetailView paint its header before — or without — a
// network round trip.
@Model
final class ShowRecord {
    @Attribute(.unique) var id: String
    var title: String
    var author: String
    var feedUrl: String
    var artworkUrl: String?
    var showDescription: String?
    var categories: [String]
    var cachedAt: Date

    init(
        id: String,
        title: String,
        author: String,
        feedUrl: String,
        artworkUrl: String?,
        showDescription: String?,
        categories: [String],
        cachedAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.feedUrl = feedUrl
        self.artworkUrl = artworkUrl
        self.showDescription = showDescription
        self.categories = categories
        self.cachedAt = cachedAt
    }

    convenience init(from show: Show, cachedAt: Date = .now) {
        self.init(
            id: show.id,
            title: show.title,
            author: show.author,
            feedUrl: show.feedUrl,
            artworkUrl: show.artworkUrl,
            showDescription: show.description,
            categories: show.categories,
            cachedAt: cachedAt)
    }

    var show: Show {
        Show(
            id: id,
            title: title,
            author: author,
            feedUrl: feedUrl,
            artworkUrl: artworkUrl,
            description: showDescription,
            categories: categories)
    }
}
