import Foundation
import SwiftData

// Per-show paging bookkeeping for the cached episode list: the continuation token to resume
// "Load more" from, and whether the last page has been reached.
@Model
final class ShowEpisodePageRecord {
    @Attribute(.unique) var showId: String
    var continuationToken: String?
    var cachedAt: Date

    init(showId: String, continuationToken: String?, cachedAt: Date = .now) {
        self.showId = showId
        self.continuationToken = continuationToken
        self.cachedAt = cachedAt
    }
}

// Single-row store for the pieces of catalog state that aren't per-entity: the derived
// per-show unplayed counts and the in-progress show ids that drive the Library unplayed
// badges and caught-up sink, plus the timestamp of the last successful catalog refresh
// (shown in Settings). JSON blobs keep this to one row rather than more @Model types for
// data that's always read and written as a whole. Only the *computed* unplayed counts are
// stored, not the raw NewEpisode feed (neither NewEpisode nor Episode is Encodable, and the
// "New Episodes" screen keeps its own live fetch).
@Model
final class CatalogCacheState {
    // There is only ever one row; a fixed id makes it a straight fetch-or-create.
    @Attribute(.unique) var id: String
    var lastRefreshedAt: Date?
    // JSON [showId: unplayedCount]; rehydrated through UnplayedCounts.counts(fromUnplayedByShow:).
    var unplayedCountsData: Data?
    // JSON [showId] (an array on the wire; consumed as a Set).
    var inProgressShowIdsData: Data?

    init(
        id: String = "singleton",
        lastRefreshedAt: Date? = nil,
        unplayedCountsData: Data? = nil,
        inProgressShowIdsData: Data? = nil
    ) {
        self.id = id
        self.lastRefreshedAt = lastRefreshedAt
        self.unplayedCountsData = unplayedCountsData
        self.inProgressShowIdsData = inProgressShowIdsData
    }
}
