import Foundation
import SwiftData

// Coordinates a manual refresh of the on-device catalog cache (subscriptions, shows, per-show
// episode pages) and, in the same pass, the three bidirectional SyncEngines (episode state,
// playlists, settings). Injected through the environment like the sync engines
// (CatalogRefreshEnvironment.swift) and constructed once in KuullaApp.init.
//
// The catalog half is a plain read-through cache — see CatalogCache — so this just fetches the
// REST endpoints and writes their responses into SwiftData through the container's main
// context (the same one views read from via `@Environment(\.modelContext)`, so a refresh is
// visible to an on-screen list immediately).
@MainActor
@Observable
final class CatalogRefreshService {
    private(set) var isRefreshing = false
    private(set) var lastRefreshedAt: Date?
    private(set) var lastError: String?
    // Human-readable progress for the "Sync Now" row, so a slow sync (e.g. a large library's
    // first full pull) shows more than a bare spinner. nil whenever isRefreshing is false.
    private(set) var statusMessage: String?

    private let context: ModelContext
    private let subscriptionClient: SubscriptionClient
    private let catalogClient: PodcastCatalogClient
    private let episodeSyncEngine: SyncEngine<EpisodeSyncAdapter>
    private let playlistSyncEngine: SyncEngine<PlaylistSyncAdapter>
    private let settingsSyncEngine: SyncEngine<SettingsSyncAdapter>

    init(
        modelContainer: ModelContainer,
        episodeSyncEngine: SyncEngine<EpisodeSyncAdapter>,
        playlistSyncEngine: SyncEngine<PlaylistSyncAdapter>,
        settingsSyncEngine: SyncEngine<SettingsSyncAdapter>,
        subscriptionClient: SubscriptionClient = SubscriptionClient(),
        catalogClient: PodcastCatalogClient = PodcastCatalogClient()
    ) {
        self.context = modelContainer.mainContext
        self.episodeSyncEngine = episodeSyncEngine
        self.playlistSyncEngine = playlistSyncEngine
        self.settingsSyncEngine = settingsSyncEngine
        self.subscriptionClient = subscriptionClient
        self.catalogClient = catalogClient
        self.lastRefreshedAt = CatalogCache.lastRefreshedAt(in: context)
    }

    // Full refresh: subscriptions + the unplayed/in-progress snapshot + page 1 of every
    // subscribed show's episode list, plus the three SyncEngines. Safe to call repeatedly; a
    // second call while one is in flight is ignored.
    func refreshAll() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        lastError = nil
        statusMessage = "Checking subscriptions…"
        defer {
            isRefreshing = false
            statusMessage = nil
        }

        // Sync engines run independently of the catalog fetches — kick them off up front.
        async let episodeSync: Void = episodeSyncEngine.syncNow()
        async let playlistSync: Void = playlistSyncEngine.syncNow()
        async let settingsSync: Void = settingsSyncEngine.syncNow()

        var hadError = false
        do {
            async let subscriptionsTask = subscriptionClient.getSubscriptions()
            async let newEpisodesTask = try? subscriptionClient.getNewEpisodes()
            async let inProgressTask = try? subscriptionClient.getInProgressShowIds()

            let subscriptions = try await subscriptionsTask
            CatalogCache.replaceSubscriptions(subscriptions, in: context)

            // Warm the New Episodes feed cache so FeedView paints instantly on cold launch (#534).
            let newEpisodes = await newEpisodesTask
            if let newEpisodes {
                CatalogCache.replaceNewEpisodes(newEpisodes, in: context)
            }
            let unplayed = newEpisodes.map(UnplayedCounts.compute(from:))
            let inProgress = await inProgressTask

            // Re-pull a subscribed show's episodes when we've never cached its episodes, or when
            // its subscription says a newer episode exists than the newest one we hold. Caching
            // the show itself — not just the episode list — is what lets ShowDetailView paint
            // (and stay usable offline) for a subscribed show the user hasn't opened since the
            // cache was seeded.
            let showIdsToRefresh = subscriptions.filter { subscription in
                guard CatalogCache.show(id: subscription.showId, in: context) != nil else { return true }
                guard CatalogCache.hasEpisodes(showId: subscription.showId, in: context) else { return true }
                guard let latest = subscription.latestEpisodePublishedAt else { return true }
                guard let cached = CatalogCache.newestEpisodeDate(showId: subscription.showId, in: context)
                else { return true }
                return latest > cached
            }.map(\.showId)
            let showIdsToRefreshSet = Set(showIdsToRefresh)

            // Show metadata (title/artwork/description) can change on the server with no new
            // episode, so the episode-recency check above never catches it. Refresh metadata for
            // every already-cached subscribed show on every sync — cheap relative to the episode
            // page fetch below, and it's what keeps title/artwork current (#746). Shows in
            // showIdsToRefresh already get fresh metadata as part of that fetch below.
            let metadataOnlyShowIds = subscriptions
                .map(\.showId)
                .filter { !showIdsToRefreshSet.contains($0) }

            // At most `maxConcurrent` requests in flight so a first sync of a large library
            // doesn't fire dozens of parallel requests. Deeper pages reload lazily on scroll.
            let maxConcurrent = 6
            var episodesComplete = true
            var index = 0
            var showsSynced = 0
            let showsTotal = showIdsToRefresh.count
            if showsTotal > 0 {
                statusMessage = "Syncing shows (0 of \(showsTotal))…"
            }
            while index < showIdsToRefresh.count {
                let batch = Array(showIdsToRefresh[index..<min(index + maxConcurrent, showIdsToRefresh.count)])
                index += maxConcurrent
                await withTaskGroup(of: (String, Show?, EpisodePage?).self) { group in
                    for showId in batch {
                        group.addTask { [catalogClient] in
                            async let show = try? await catalogClient.getShow(id: showId)
                            async let page = try? await catalogClient.getEpisodes(
                                showId: showId, continuationToken: nil)
                            return (showId, await show ?? nil, await page)
                        }
                    }
                    for await (showId, show, page) in group {
                        if let show {
                            CatalogCache.upsertShow(show, in: context)
                        }
                        showsSynced += 1
                        statusMessage = "Syncing shows (\(showsSynced) of \(showsTotal))…"
                        guard let page else {
                            episodesComplete = false
                            continue
                        }
                        CatalogCache.replaceEpisodes(
                            showId: showId, page.items, continuationToken: page.continuationToken,
                            in: context)
                    }
                }
            }

            index = 0
            while index < metadataOnlyShowIds.count {
                let batch = Array(
                    metadataOnlyShowIds[index..<min(index + maxConcurrent, metadataOnlyShowIds.count)])
                index += maxConcurrent
                await withTaskGroup(of: Show?.self) { group in
                    for showId in batch {
                        group.addTask { [catalogClient] in
                            try? await catalogClient.getShow(id: showId)
                        }
                    }
                    for await show in group {
                        if let show {
                            CatalogCache.upsertShow(show, in: context)
                        }
                    }
                }
            }

            // A full sync means everything best-effort actually landed — only then advance the
            // "last synced" clock (storeSnapshot ignores a nil `refreshedAt`).
            let fullySynced = unplayed != nil && inProgress != nil && episodesComplete
            CatalogCache.storeSnapshot(
                unplayedCounts: unplayed, inProgressShowIds: inProgress,
                refreshedAt: fullySynced ? .now : nil, in: context)
            if !fullySynced {
                lastError = "Some of your library couldn't be synced. Try again."
            }
        } catch {
            hadError = true
            lastError = "Couldn't sync your library. Check your connection and try again."
        }

        statusMessage = "Syncing playback & playlists…"
        _ = await (episodeSync, playlistSync, settingsSync)

        if !hadError {
            lastRefreshedAt = CatalogCache.lastRefreshedAt(in: context)
        }
    }

    // Refresh one show in place — used by ShowDetailView's pull-to-refresh. Doesn't touch the
    // subscription list or the sync engines.
    func refreshShow(showId: String) async {
        do {
            if let show = try await catalogClient.getShow(id: showId) {
                CatalogCache.upsertShow(show, in: context)
            }
            let page = try await catalogClient.getEpisodes(showId: showId, continuationToken: nil)
            CatalogCache.replaceEpisodes(
                showId: showId, page.items, continuationToken: page.continuationToken, in: context)
        } catch {
            // Best-effort — the cached copy stays on screen.
        }
    }
}
