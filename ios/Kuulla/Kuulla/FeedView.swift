import SwiftData
import SwiftUI

struct FeedView: View {
    @Environment(\.episodeSyncEngine) private var syncEngine
    @Environment(\.catalogRefresh) private var catalogRefresh
    @Environment(\.modelContext) private var modelContext

    @State private var feedItems: [NewEpisode] = []
    // Most of this view works in terms of the bare Episode; feedItems additionally carries the
    // per-row show identity (#441) that FeedEpisodeRow renders.
    private var episodes: [Episode] { feedItems.map(\.episode) }
    // The ordered snapshot PlaybackQueue advances through when "play next" is armed from this
    // screen (#629) — the New Episodes list as currently shown.
    private var playbackList: PlaybackList {
        PlaybackList(
            source: .newEpisodes,
            items: feedItems.map { PlaybackQueue.QueueItem(showId: $0.episode.showId, episodeId: $0.episode.id) })
    }
    @State private var statusByEpisodeId: [String: EpisodeStatus] = [:]
    @State private var downloadStatusByEpisodeId: [String: DownloadStatus] = [:]
    @State private var isLoading = false
    // Flips true after the first (synchronous) read of the local cache — the spinner only shows
    // until then, mirroring SubscriptionsView (#488, #534).
    @State private var hasLoaded = false
    @State private var errorMessage: String?

    private let subscriptionClient = SubscriptionClient()
    private let settingsClient = SettingsClient()
    private let chargingStateProvider: DeviceChargingStateProviding = UIDeviceChargingStateProvider()

    var body: some View {
        // A List (rather than ScrollView + LazyVStack, as before), matching ShowDetailView — its
        // UIKit-backed row hosting reliably separates a nested control's tap target (the Restore
        // button below) from the row's own NavigationLink activation, which a plain LazyVStack
        // does not reliably do.
        List {
            if let errorMessage, feedItems.isEmpty {
                Text(errorMessage)
                    .foregroundStyle(.red)
            } else if !hasLoaded || (isLoading && feedItems.isEmpty) {
                // Spinner only when there's nothing cached to show yet — a background refresh
                // over an already-populated list stays silent.
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else if episodes.isEmpty {
                Text("You're all caught up — no new episodes from your subscriptions.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(feedItems, id: \.episode.id) { item in
                    let episode = item.episode
                    NavigationLink(value: CatalogRoute.episode(showId: episode.showId, episodeId: episode.id, list: playbackList)) {
                        FeedEpisodeRow(
                            item: item,
                            status: statusByEpisodeId[episode.id] ?? .new,
                            downloadStatus: downloadStatusByEpisodeId[episode.id],
                            onRestore: { Task { await restoreAutoPlayed(episodeId: episode.id) } },
                            onDownloadDidFinish: refreshStatuses)
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("New Episodes")
        .task {
            // Paint instantly from the local cache (#534), then refresh from the network.
            readLocalFeed()
            await load()
        }
        .onAppear {
            // Cheap local-only re-read (no network) so a badge marked played/in-progress from the
            // detail screen — or a cold-launch / Settings "Sync Now" refresh landing while this
            // screen was pushed away — isn't left stale. SwiftUI doesn't re-run .task just
            // because a pushed NavigationLink destination was popped.
            readLocalFeed()
        }
        .onChange(of: catalogRefresh?.isRefreshing) { _, _ in
            readLocalFeed()
        }
        .refreshable {
            await syncEngine?.syncNow()
            await load()
        }
    }

    // Synchronous paint from the on-device catalog cache (#534) — no network.
    private func readLocalFeed() {
        feedItems = Self.displayItems(from: CatalogCache.newEpisodes(in: modelContext))
        hasLoaded = true
        refreshStatuses()
    }

    private func load() async {
        guard !isLoading else { return }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let results = try await subscriptionClient.getNewEpisodes()
            guard !Task.isCancelled else { return }
            CatalogCache.replaceNewEpisodes(results, in: modelContext)
            feedItems = Self.displayItems(from: results)
            hasLoaded = true
            refreshStatuses()
            await triggerAutoDownloads()
        } catch {
            guard !Task.isCancelled else { return }
            // Keep any cached rows on screen — only surface the error when there's nothing to show.
            if feedItems.isEmpty {
                errorMessage = "Something went wrong while loading your new episodes. Please try again."
            }
        }
    }

    // Excludes autoPlayed episodes — they're already marked played by the unlistened-episode
    // limit, so they shouldn't clutter the "New Episodes" list (mirrors NewEpisodes.razor on
    // Web). A restore path for those still exists via ShowDetailView's status filter chips.
    // Pulled out as a pure function for testability, matching `shouldAutoDownload`.
    static func displayItems(from items: [NewEpisode]) -> [NewEpisode] {
        items
            .filter { !$0.autoPlayed }
            .sorted { ($0.episode.publishedAt ?? .distantPast) > ($1.episode.publishedAt ?? .distantPast) }
    }

    // #270: no new episode-detection mechanism — this reuses getNewEpisodes(), the same
    // server-side "new episode" signal load() already fetches, rather than inventing a second
    // one. Only considers episodes with no DownloadedEpisodeRecord at all: one that's already
    // .downloading/.complete/.failed was touched by something else (a manual tap, a previous
    // auto-download) and re-triggering it here on every refresh would be at best redundant, at
    // worst a wasted re-download (or silently retrying a .failed one the user hasn't asked to retry).
    private func triggerAutoDownloads() async {
        let candidates = episodes.filter { downloadStatusByEpisodeId[$0.id] == nil }
        guard !candidates.isEmpty else { return }

        let globalSettings = try? await settingsClient.getSettings()
        let globalDefault = globalSettings?.autoDownloadNewEpisodes ?? false
        let globalEpisodeLimit = globalSettings?.autoDownloadEpisodeLimit ?? 0
        let globalChargingOnly = globalSettings?.autoDownloadChargingOnly ?? false
        let showSettingsById = await fetchShowSettings(for: Set(candidates.map(\.showId)))
        // Read once per round rather than per episode — battery state doesn't change fast enough
        // for that distinction to matter, and it keeps every episode in this round evaluated
        // against the same charging snapshot.
        let isCharging = chargingStateProvider.isCharging

        var showIdsWithNewDownloads: Set<String> = []
        for episode in candidates {
            // A show whose settings fetch failed has no key here at all — distinct from a show
            // that was fetched successfully and has no override (present with a nil value).
            // Falling through to the global default for a failed fetch would risk silently
            // overriding a user's explicit per-show opt-out (override == false) with a
            // transient network hiccup; skipping this episode for this round instead fails
            // closed, and the next refresh gets another chance to resolve it correctly.
            guard let showSettings = showSettingsById[episode.showId] else { continue }
            guard Self.shouldAutoDownload(
                downloadStatus: downloadStatusByEpisodeId[episode.id],
                showOverride: showSettings.autoDownloadNewEpisodes, globalDefault: globalDefault
            ) else { continue }

            let chargingOnly = showSettings.autoDownloadChargingOnly ?? globalChargingOnly
            guard Self.isAutoDownloadAllowedRightNow(chargingOnly: chargingOnly, isCharging: isCharging) else { continue }

            DownloadManager.shared.startDownload(episode: episode)
            showIdsWithNewDownloads.insert(episode.showId)
        }

        // #689's "latest N episodes" rule — enforced after starting this round's downloads (not
        // before), so a show whose limit was just reached still gets the newest episode before
        // anything is evicted.
        for showId in showIdsWithNewDownloads {
            let limit = showSettingsById[showId]?.autoDownloadEpisodeLimit ?? globalEpisodeLimit
            DownloadManager.shared.enforceEpisodeLimit(showId: showId, limit: limit, in: modelContext)
        }

        // startDownload writes a .downloading DownloadedEpisodeRecord synchronously — including
        // for a Wi-Fi-only download that's merely queued, not yet an actual transfer (#180), the
        // one case DownloadButton's own live-progress override can't cover on its own, since
        // DownloadManager.progress has no entry for a queued episode either. Without this,
        // affected rows would keep showing the down-arrow until something else happened to
        // trigger a refresh.
        if !showIdsWithNewDownloads.isEmpty {
            refreshStatuses()
        }
    }

    // Pulled out as a pure function for testability, mirroring the codebase's established
    // pattern (EpisodeDetailView.resolvedPlaybackURL, DownloadButton.effectiveStatus).
    static func shouldAutoDownload(downloadStatus: DownloadStatus?, showOverride: Bool?, globalDefault: Bool) -> Bool {
        guard downloadStatus == nil else { return false }
        return showOverride ?? globalDefault
    }

    // #689's "charging only" auto-download condition — unlike Wi-Fi-only downloads (#180), this
    // has no queue: it's re-checked on every feed refresh, so an episode simply auto-downloads on
    // the next refresh that happens to land while charging rather than waiting on a live observer.
    static func isAutoDownloadAllowedRightNow(chargingOnly: Bool, isCharging: Bool) -> Bool {
        !chargingOnly || isCharging
    }

    // Bounded concurrency (mirroring DownloadsView's episode-metadata fetch) rather than one
    // request per distinct show at once — a user subscribed to many shows with new episodes
    // shouldn't burst-request the API for every one of them simultaneously. A show whose fetch
    // fails is left out of the returned dictionary entirely (not inserted with a nil value) —
    // triggerAutoDownloads relies on that key's absence to distinguish "fetch failed" from
    // "fetched fine, no override" and skip the episode rather than guessing. Returns the whole
    // ShowSettings (rather than just the on/off override, as before #689) so the auto-download,
    // episode-limit, and charging-only overrides all come from the one request per show.
    private func fetchShowSettings(for showIds: Set<String>) async -> [String: ShowSettings] {
        var settingsByShowId: [String: ShowSettings] = [:]
        let maxConcurrentRequests = 4
        var iterator = showIds.makeIterator()

        await withTaskGroup(of: (showId: String, settings: ShowSettings?).self) { group in
            func addTaskIfAvailable() {
                guard let showId = iterator.next() else { return }
                group.addTask {
                    (showId, try? await self.settingsClient.getShowSettings(showId: showId))
                }
            }

            for _ in 0..<min(maxConcurrentRequests, showIds.count) {
                addTaskIfAvailable()
            }
            for await result in group {
                if let settings = result.settings {
                    settingsByShowId[result.showId] = settings
                }
                addTaskIfAvailable()
            }
        }

        return settingsByShowId
    }

    private func restoreAutoPlayed(episodeId: String) async {
        // Derive the badge directly from the returned record rather than refreshStatuses() — that
        // re-fetches every record through this view's own ModelContext, a different instance than
        // the one the write just saved through (same hazard EpisodeDetailView.persist() avoids).
        guard let restored = await syncEngine?.restoreAutoPlayed(episodeId: episodeId) else { return }
        statusByEpisodeId[episodeId] = EpisodeStatus(record: restored)
        CatalogCache.recordEpisodeStateChange(
            episodeId: episodeId, showId: restored.showId, completed: restored.completed,
            positionSeconds: restored.positionSeconds, in: modelContext)
    }

    private func refreshStatuses() {
        let episodeIds = Set(episodes.map(\.id))
        statusByEpisodeId = EpisodeStatus.statusMap(for: episodeIds, in: modelContext)
        downloadStatusByEpisodeId = DownloadStatus.statusMap(for: episodeIds, in: modelContext)
    }
}

private struct FeedEpisodeRow: View {
    let item: NewEpisode
    let status: EpisodeStatus
    let downloadStatus: DownloadStatus?
    let onRestore: () -> Void
    let onDownloadDidFinish: () -> Void

    private var episode: Episode { item.episode }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ShowArtworkThumbnail(url: item.showArtworkUrl.flatMap(URL.init))

            VStack(alignment: .leading, spacing: 4) {
                Text(episode.title)
                    .font(.body)
                    .lineLimit(2)
                    .foregroundStyle(.primary)

                if !item.showTitle.isEmpty {
                    Text(item.showTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 4) {
                    if let publishedAt = episode.publishedAt {
                        Text(publishedAt.formatted(date: .abbreviated, time: .omitted))
                    }
                    if episode.publishedAt != nil && episode.duration != nil {
                        Text("·")
                    }
                    if let duration = episode.duration {
                        Text(EpisodeFormatting.formatDuration(duration))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 8) {
                StatusBadgeWithRestore(status: status, onRestore: onRestore)
                DownloadButton(episode: episode, status: downloadStatus, onDidFinish: onDownloadDidFinish)
            }
        }
        .padding()
    }
}

// Small square show-artwork thumbnail for a feed row. Mirrors LibraryView.ShowTile's AsyncImage
// treatment; a missing or still-loading URL falls back to a tinted placeholder rather than a
// broken image (#441).
private struct ShowArtworkThumbnail: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            ZStack {
                Color.secondary.opacity(0.2)
                Image(systemName: "mic")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 48, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

#Preview {
    NavigationStack {
        FeedView()
    }
    .modelContainer(for: EpisodeStateRecord.self, inMemory: true)
}
