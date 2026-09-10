import Foundation
import SwiftData

// Synchronous read/write helpers over the on-device catalog cache (SubscriptionRecord,
// ShowRecord, CachedEpisodeRecord, ShowEpisodePageRecord, CatalogCacheState). Mirrors the
// `PlaylistSummary.list(from:)` style: views call these against their
// `@Environment(\.modelContext)` for instant paint, and CatalogRefreshService calls the
// `replace`/`upsert` side after a network fetch.
//
// This is a plain cache, not a `SyncEngine` domain — there is no bidirectional reconciliation,
// no dirty tracking, and writes always take the server's copy as authoritative.
enum CatalogCache {
    // MARK: Subscriptions

    static func subscriptions(in context: ModelContext) -> [Subscription] {
        let records = (try? context.fetch(FetchDescriptor<SubscriptionRecord>())) ?? []
        return records.map(\.subscription)
    }

    // Replaces the whole cached set: upserts every incoming row and deletes any local row the
    // server no longer returns (an unsubscribe that happened on another device).
    static func replaceSubscriptions(_ subscriptions: [Subscription], in context: ModelContext) {
        let incomingIds = Set(subscriptions.map(\.id))
        let existing = (try? context.fetch(FetchDescriptor<SubscriptionRecord>())) ?? []
        let byId = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        for subscription in subscriptions {
            if let record = byId[subscription.id] {
                record.userId = subscription.userId
                record.showId = subscription.showId
                record.showTitle = subscription.showTitle
                record.showAuthor = subscription.showAuthor
                record.showArtworkUrl = subscription.showArtworkUrl
                record.subscribedAt = subscription.subscribedAt
                record.latestEpisodePublishedAt = subscription.latestEpisodePublishedAt
                record.cachedAt = .now
            } else {
                context.insert(SubscriptionRecord(from: subscription))
            }
        }
        for record in existing where !incomingIds.contains(record.id) {
            context.delete(record)
        }
        try? context.save()
    }

    // Point updates for the local subscribe/unsubscribe path in ShowDetailView, so the Library
    // reflects the change without waiting for a full refresh.
    static func upsertSubscription(_ subscription: Subscription, in context: ModelContext) {
        let id = subscription.id
        if let record = try? context.fetch(
            FetchDescriptor<SubscriptionRecord>(predicate: #Predicate { $0.id == id })
        ).first {
            record.cachedAt = .now
            record.showId = subscription.showId
        } else {
            context.insert(SubscriptionRecord(from: subscription))
        }
        try? context.save()
    }

    static func removeSubscription(showId: String, in context: ModelContext) {
        let matches = (try? context.fetch(
            FetchDescriptor<SubscriptionRecord>(predicate: #Predicate { $0.showId == showId })
        )) ?? []
        for record in matches {
            context.delete(record)
        }
        try? context.save()
    }

    // MARK: Shows

    static func show(id: String, in context: ModelContext) -> Show? {
        (try? context.fetch(
            FetchDescriptor<ShowRecord>(predicate: #Predicate { $0.id == id })
        ).first)?.show
    }

    static func upsertShow(_ show: Show, in context: ModelContext) {
        let id = show.id
        if let record = try? context.fetch(
            FetchDescriptor<ShowRecord>(predicate: #Predicate { $0.id == id })
        ).first {
            record.title = show.title
            record.author = show.author
            record.feedUrl = show.feedUrl
            record.artworkUrl = show.artworkUrl
            record.showDescription = show.description
            record.categories = show.categories
            record.cachedAt = .now
        } else {
            context.insert(ShowRecord(from: show))
        }
        try? context.save()
    }

    // MARK: Episodes

    static func episodes(showId: String, in context: ModelContext) -> [Episode] {
        let records = (try? context.fetch(
            FetchDescriptor<CachedEpisodeRecord>(
                predicate: #Predicate { $0.showId == showId },
                sortBy: [SortDescriptor(\.sortIndex)])
        )) ?? []
        return records.map(\.episode)
    }

    static func hasEpisodes(showId: String, in context: ModelContext) -> Bool {
        var descriptor = FetchDescriptor<CachedEpisodeRecord>(
            predicate: #Predicate { $0.showId == showId })
        descriptor.fetchLimit = 1
        return ((try? context.fetchCount(descriptor)) ?? 0) > 0
    }

    // Publish date of the newest cached episode for a show — compared against a subscription's
    // `latestEpisodePublishedAt` to decide whether a refresh needs to re-pull that show.
    static func newestEpisodeDate(showId: String, in context: ModelContext) -> Date? {
        var descriptor = FetchDescriptor<CachedEpisodeRecord>(
            predicate: #Predicate { $0.showId == showId },
            sortBy: [SortDescriptor(\.publishedAt, order: .reverse)])
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first?.publishedAt
    }

    static func continuationToken(showId: String, in context: ModelContext) -> String? {
        (try? context.fetch(
            FetchDescriptor<ShowEpisodePageRecord>(predicate: #Predicate { $0.showId == showId })
        ).first)?.continuationToken
    }

    // First page (or a full refresh) of a show's episode list: drops every cached row for the
    // show and re-seeds from `episodes`, starting `sortIndex` at 0.
    static func replaceEpisodes(
        showId: String, _ episodes: [Episode], continuationToken: String?, in context: ModelContext
    ) {
        let stale = (try? context.fetch(
            FetchDescriptor<CachedEpisodeRecord>(predicate: #Predicate { $0.showId == showId })
        )) ?? []
        for record in stale {
            context.delete(record)
        }
        for (offset, episode) in episodes.enumerated() {
            context.insert(CachedEpisodeRecord(from: episode, showId: showId, sortIndex: offset))
        }
        setContinuationToken(continuationToken, showId: showId, in: context)
        try? context.save()
    }

    // A subsequent "Load more" page: appends after the current highest sortIndex.
    static func appendEpisodes(
        showId: String, _ episodes: [Episode], continuationToken: String?, in context: ModelContext
    ) {
        let existing = (try? context.fetch(
            FetchDescriptor<CachedEpisodeRecord>(predicate: #Predicate { $0.showId == showId })
        )) ?? []
        let existingIds = Set(existing.map(\.id))
        var nextIndex = (existing.map(\.sortIndex).max() ?? -1) + 1
        for episode in episodes where !existingIds.contains(episode.id) {
            context.insert(CachedEpisodeRecord(from: episode, showId: showId, sortIndex: nextIndex))
            nextIndex += 1
        }
        setContinuationToken(continuationToken, showId: showId, in: context)
        try? context.save()
    }

    private static func setContinuationToken(_ token: String?, showId: String, in context: ModelContext) {
        if let record = try? context.fetch(
            FetchDescriptor<ShowEpisodePageRecord>(predicate: #Predicate { $0.showId == showId })
        ).first {
            record.continuationToken = token
            record.cachedAt = .now
        } else {
            context.insert(ShowEpisodePageRecord(showId: showId, continuationToken: token))
        }
    }

    // MARK: New Episodes feed

    // The whole cached feed in the server's returned order. FeedView filters out `autoPlayed`
    // rows for display; they're kept here so the cache stays a faithful mirror of the endpoint
    // (and feeds UnplayedCounts, which needs them).
    static func newEpisodes(in context: ModelContext) -> [NewEpisode] {
        let records = (try? context.fetch(
            FetchDescriptor<CachedNewEpisodeRecord>(sortBy: [SortDescriptor(\.sortIndex)])
        )) ?? []
        return records.map(\.newEpisode)
    }

    // Replaces the whole cached feed: drops every existing row and re-seeds from `newEpisodes`,
    // starting `sortIndex` at 0. Mirrors replaceEpisodes — writes always take the server's copy
    // as authoritative.
    static func replaceNewEpisodes(_ newEpisodes: [NewEpisode], in context: ModelContext) {
        let stale = (try? context.fetch(FetchDescriptor<CachedNewEpisodeRecord>())) ?? []
        for record in stale {
            context.delete(record)
        }
        for (offset, newEpisode) in newEpisodes.enumerated() {
            context.insert(CachedNewEpisodeRecord(from: newEpisode, sortIndex: offset))
        }
        try? context.save()
    }

    // MARK: Snapshot state (unplayed badges, caught-up sink, last-synced)

    // Nil when nothing has been written yet — read helpers below must not create the row, so a
    // plain cache read never has a write side effect.
    private static func existingState(in context: ModelContext) -> CatalogCacheState? {
        try? context.fetch(FetchDescriptor<CatalogCacheState>()).first
    }

    private static func state(in context: ModelContext) -> CatalogCacheState {
        if let existing = existingState(in: context) {
            return existing
        }
        let created = CatalogCacheState()
        context.insert(created)
        return created
    }

    static func unplayedCounts(in context: ModelContext) -> [String: UnplayedCounts.Count] {
        guard let data = existingState(in: context)?.unplayedCountsData,
              let byShow = try? JSONDecoder().decode([String: Int].self, from: data)
        else { return [:] }
        return UnplayedCounts.counts(fromUnplayedByShow: byShow)
    }

    static func inProgressShowIds(in context: ModelContext) -> Set<String> {
        guard let data = existingState(in: context)?.inProgressShowIdsData,
              let ids = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(ids)
    }

    static func lastRefreshedAt(in context: ModelContext) -> Date? {
        existingState(in: context)?.lastRefreshedAt
    }

    // `refreshedAt` is nil for a partial sync (some best-effort fetch failed) — the snapshot data
    // that did arrive is still stored, but the "last synced" clock isn't advanced, so Settings
    // doesn't claim a full sync that didn't happen.
    static func storeSnapshot(
        unplayedCounts: [String: UnplayedCounts.Count]?,
        inProgressShowIds: Set<String>?,
        refreshedAt: Date?,
        in context: ModelContext
    ) {
        let row = state(in: context)
        if let unplayedCounts {
            row.unplayedCountsData = try? JSONEncoder().encode(
                UnplayedCounts.unplayedByShow(from: unplayedCounts))
        }
        if let inProgressShowIds {
            row.inProgressShowIdsData = try? JSONEncoder().encode(Array(inProgressShowIds))
        }
        if let refreshedAt {
            row.lastRefreshedAt = refreshedAt
        }
        try? context.save()
    }

    // Drop a single show from the snapshot blobs so a just-unsubscribed show stops showing a
    // stale unplayed badge / counting as "active" before the next full refresh (#533).
    static func removeShowFromSnapshot(showId: String, in context: ModelContext) {
        guard let row = existingState(in: context) else { return }
        if let data = row.unplayedCountsData,
           var byShow = try? JSONDecoder().decode([String: Int].self, from: data),
           byShow.removeValue(forKey: showId) != nil {
            row.unplayedCountsData = try? JSONEncoder().encode(byShow)
        }
        if let data = row.inProgressShowIdsData,
           var ids = try? JSONDecoder().decode([String].self, from: data),
           let index = ids.firstIndex(of: showId) {
            ids.remove(at: index)
            row.inProgressShowIdsData = try? JSONEncoder().encode(ids)
        }
        try? context.save()
    }
}
