import CarPlay
import CryptoKit
import SwiftData
import UIKit

// Connects/tears down the CPInterfaceController for CarPlay's template scene, and drives the
// browse UI: subscriptions -> episodes -> Now Playing. Reuses the same clients/state as the
// phone UI (SubscriptionClient, PodcastCatalogClient, EpisodeStatus, EpisodeDetailView's
// resolvedPlaybackURL) rather than hand-rolling CarPlay-specific data access or a second,
// divergent playback-progress path.
// @MainActor to match EpisodeDetailView's own reasoning: AudioPlayer's properties are only ever
// mutated on the main queue (its periodic time observer and NotificationCenter observer both use
// queue: .main), and CPInterfaceController's template calls need to happen on main too — every
// Task {} this delegate creates should inherit main-actor isolation rather than resuming on
// whatever arbitrary executor CPTemplateApplicationSceneDelegate's callbacks land on.
@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    // Set once by KuullaApp.init(), mirroring DownloadManager.shared.configure(modelContainer:) —
    // CarPlay's scene delegate is instantiated by UIKit, not SwiftUI, so it has no @Environment
    // to read the app's shared instances from.
    static var modelContainer: ModelContainer?
    static var episodeSyncEngine: SyncEngine<EpisodeSyncAdapter>?
    static var settingsSyncEngine: SyncEngine<SettingsSyncAdapter>?
    static var playlistSyncEngine: SyncEngine<PlaylistSyncAdapter>?

    var interfaceController: CPInterfaceController?

    private let subscriptionClient = SubscriptionClient()
    private let catalogClient = PodcastCatalogClient()
    private let settingsClient = SettingsClient()
    private let playlistClient = PlaylistClient()

    // Best-effort artwork cache keyed by URL string — the episodes list reuses the same show
    // artwork URL for every row, so without this every row would re-fetch it independently.
    private var imageCache: [String: UIImage] = [:]

    // Tracked so disconnecting from CarPlay cancels in-flight loads/saves rather than leaking a
    // Task that keeps running (and, for progressTrackingTask, keeps writing) after there's no
    // CarPlay session left to have driven it.
    private var loadTask: Task<Void, Never>?
    private var progressTrackingTask: Task<Void, Never>?
    private var episodeSyncTask: Task<Void, Never>?
    private var settingsSyncTask: Task<Void, Never>?
    private var playlistSyncTask: Task<Void, Never>?

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController

        // Root is a tab bar (#641) rather than a bare subscriptions list, so playlists get their
        // own browse surface alongside shows instead of a section wedged into one or the other.
        let showsTemplate = Self.emptyListTemplate(title: "Kuulla")
        showsTemplate.tabTitle = "Shows"
        showsTemplate.tabImage = UIImage(systemName: "mic")
        let playlistsTemplate = Self.emptyListTemplate(title: "Playlists")
        playlistsTemplate.tabTitle = "Playlists"
        playlistsTemplate.tabImage = UIImage(systemName: "music.note.list")
        interfaceController.setRootTemplate(
            CPTabBarTemplate(templates: [showsTemplate, playlistsTemplate]), animated: false, completion: nil)

        // Set once per connect (#640/#642) — CPNowPlayingTemplate.shared is a singleton for the
        // whole CarPlay session, so this doesn't need re-wiring per playback session the way
        // AudioPlayer's onDidFinishPlaying handler does. Skip back/forward already work for free
        // via AudioPlayer.configureRemoteCommandCenter's MPRemoteCommandCenter wiring. CarPlay
        // reports Up Next taps through the CPNowPlayingTemplateObserver protocol rather than a
        // closure property. The four action buttons (Mark Played / Download / Add to Playlist /
        // Playback Speed) sit directly on the Now Playing screen as their own buttons rather than
        // behind a single "More" menu — CPListItem itself has no secondary tap target (no swipe,
        // no long-press, no accessory-button handler in the CarPlay SDK) and a hidden-behind-a-menu
        // control takes an extra tap while driving, so each option gets its own glanceable button
        // (CarPlay allows up to 5 on CPNowPlayingTemplate).
        CPNowPlayingTemplate.shared.isUpNextButtonEnabled = true
        CPNowPlayingTemplate.shared.add(self)
        updateNowPlayingActionButtons()

        // Kicked off up front, in parallel with the cache-painted list load below, rather than
        // waited on before painting anything — CarPlay connecting is exactly the "phone app hasn't
        // been opened in a while" case (#488 turned off sync-on-every-foreground), so without this
        // CarPlay would only ever reflect whatever the phone last synced on its own, which reads as
        // a second, out-of-sync device rather than a mirror of the one in the driver's pocket.
        // loadSubscriptionsList awaits these before its settled (network-refreshed) repaint so that
        // pass's played/caught-up state matches what just landed from the server.
        let episodeSyncEngine = Self.episodeSyncEngine
        let settingsSyncEngine = Self.settingsSyncEngine
        let playlistSyncEngine = Self.playlistSyncEngine
        let episodeSync = Task { () async -> Void in
            guard let episodeSyncEngine else { return }
            await episodeSyncEngine.syncNow()
        }
        let settingsSync = Task { () async -> Void in
            guard let settingsSyncEngine else { return }
            await settingsSyncEngine.syncNow()
        }
        let playlistSync = Task { () async -> Void in
            guard let playlistSyncEngine else { return }
            await playlistSyncEngine.syncNow()
        }
        episodeSyncTask = episodeSync
        settingsSyncTask = settingsSync
        playlistSyncTask = playlistSync

        loadTask = Task {
            async let subscriptions: Void = loadSubscriptionsList(
                into: showsTemplate, episodeSync: episodeSync, settingsSync: settingsSync)
            async let playlists: Void = loadPlaylistsList(into: playlistsTemplate, playlistSync: playlistSync)
            _ = await (subscriptions, playlists)
        }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        self.interfaceController = nil
        CPNowPlayingTemplate.shared.remove(self)
        loadTask?.cancel()
        loadTask = nil
        progressTrackingTask?.cancel()
        progressTrackingTask = nil
        episodeSyncTask?.cancel()
        episodeSyncTask = nil
        settingsSyncTask?.cancel()
        settingsSyncTask = nil
        playlistSyncTask?.cancel()
        playlistSyncTask = nil
    }

    private static func emptyListTemplate(title: String) -> CPListTemplate {
        CPListTemplate(title: title, sections: [])
    }

    // Cache-first (#637): paint instantly from CatalogCache if it has anything for this show,
    // then refresh from the network behind it — same pattern as LibraryView/ShowDetailView.
    // Sorted by the app's saved subscription sort order (#638) via the same shared
    // sortedSubscriptions(_:by:manualOrder:) LibraryView/SubscriptionsView use, rather than a
    // CarPlay-local hardcoded alphabetical order. Updates the Shows tab's own template sections in
    // place (#641) rather than setting a new root template, now that root is a CPTabBarTemplate.
    // A Continue Listening section (#639), when there's anything in progress, sits above the
    // shows list either way — it reads local EpisodeStateRecords directly rather than needing its
    // own cache-vs-network distinction, so it's computed once and reused for both paints.
    private func loadSubscriptionsList(
        into template: CPListTemplate, episodeSync: Task<Void, Never>, settingsSync: Task<Void, Never>
    ) async {
        let context = Self.modelContainer.map(ModelContext.init)

        var continueListening: CPListSection?
        if let context {
            continueListening = await continueListeningSection(in: context)
        }

        var paintedFromCache = false
        if let context {
            let cachedSubscriptions = CatalogCache.subscriptions(in: context)
            // Paints immediately whenever there's *either* a cached subscription or a Continue
            // Listening entry to show — an orphaned in-progress episode (its show unsubscribed
            // from since) shouldn't have to wait on the network subscriptions fetch just because
            // the subscriptions cache itself is empty.
            if !cachedSubscriptions.isEmpty || continueListening != nil {
                let localSettings = Self.localUserSettings(in: context)
                // Mirrors SubscriptionsView/LibraryView's "Hide caught-up shows" filter (a synced
                // setting the phone already honors) — CarPlay was ignoring it entirely and always
                // showing every subscribed show, finished or not.
                let cached = sortedSubscriptions(
                    cachedSubscriptions, by: localSettings?.subscriptionSortOrder ?? .title,
                    manualOrder: localSettings?.subscriptionManualOrder ?? [],
                    activeShowIds: Self.activeShowIds(in: context), hideCaughtUp: localSettings?.hideCaughtUpShows ?? false)
                template.updateSections([continueListening].compactMap { $0 } + subscriptionsSections(for: cached))
                paintedFromCache = true
            }
        }

        do {
            async let subscriptionsResult = subscriptionClient.getSubscriptions()
            async let settingsResult = try? settingsClient.getSettings()
            // Waited on alongside the network fetches above (kicked off in didConnect, so they're
            // already in flight) — this settled repaint reflects the played state and settings the
            // phone last synced, not whatever this device held before CarPlay connected.
            await episodeSync.value
            await settingsSync.value
            let subscriptions = try await subscriptionsResult
            let settings = await settingsResult
            if let context {
                CatalogCache.replaceSubscriptions(subscriptions, in: context)
            }
            let localSettings = context.flatMap(Self.localUserSettings)
            let activeShowIds = context.map(Self.activeShowIds)
            let sorted = sortedSubscriptions(
                subscriptions, by: settings?.subscriptionSortOrder ?? .title,
                manualOrder: settings?.subscriptionManualOrder ?? [],
                activeShowIds: activeShowIds, hideCaughtUp: settings?.hideCaughtUpShows ?? localSettings?.hideCaughtUpShows ?? false)
            template.updateSections([continueListening].compactMap { $0 } + subscriptionsSections(for: sorted))
        } catch {
            // The cache already painted something useful — leave it up rather than clobbering it
            // with an error, the same tolerance ShowDetailView.readLocalShow() gives a stale but
            // present cache when its own network follow-up fails.
            guard !paintedFromCache else { return }
            template.updateSections(
                [continueListening].compactMap { $0 }
                    + [CPListSection(items: [CPListItem(text: "Couldn't load your subscriptions.", detailText: nil)])])
        }
    }

    // Local mirror of the synced UserSettings (same store SettingsSyncAdapter/SettingsView write
    // to) — read synchronously so the cache-painted subscriptions list can honor the saved sort
    // order immediately, without waiting on the network settings fetch below.
    private static func localUserSettings(in context: ModelContext) -> UserSettingsRecord? {
        let id = UserSettingsRecord.localId
        return try? context.fetch(FetchDescriptor<UserSettingsRecord>(predicate: #Predicate { $0.id == id })).first
    }

    // Shows with at least one unplayed or in-progress episode — the complement of "caught up".
    // Mirrors SubscriptionsView.activeShowIds, but always computed (rather than nil-until-loaded)
    // since CatalogCache's underlying queries are synchronous local SwiftData reads here, with no
    // separate "has this loaded yet" state to gate on.
    private static func activeShowIds(in context: ModelContext) -> Set<String> {
        Set(CatalogCache.unplayedCounts(in: context).keys).union(CatalogCache.inProgressShowIds(in: context))
    }

    // Capped like ShowDetailView's own lists favor a short, scannable set over an exhaustive one —
    // this is a glance-and-tap surface, not a full history.
    private static let continueListeningLimit = 20

    private struct ContinueListeningEntry {
        let episode: Episode
        let show: Show?
        let positionSeconds: Int
        let downloadRecord: DownloadedEpisodeRecord?
    }

    // Cross-show "resume where you left off" (#639) — CarPlay's root has no in-show episode list
    // to filter the way EpisodeListFilter.inProgress does, so this queries the synced
    // EpisodeStateRecord store directly instead. There's no separate cache-vs-network distinction
    // for the position data itself (this local store already is the synced source of truth); only
    // each record's episode/show metadata needs resolving, cache-first via CatalogCache and
    // falling back to the network for anything CatalogCache hasn't seen (a show reached from
    // Search/Discovery rather than a subscription, say).
    private func continueListeningSection(in context: ModelContext) async -> CPListSection? {
        var descriptor = FetchDescriptor<EpisodeStateRecord>(
            predicate: #Predicate<EpisodeStateRecord> { !$0.completed && $0.positionSeconds > 0 && !$0.archived },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        descriptor.fetchLimit = Self.continueListeningLimit
        let records = (try? context.fetch(descriptor)) ?? []
        guard !records.isEmpty else { return nil }

        let episodeIds = Set(records.map(\.id))
        let downloadDescriptor = FetchDescriptor<DownloadedEpisodeRecord>(predicate: #Predicate { episodeIds.contains($0.id) })
        let downloadRecords = Dictionary(
            uniqueKeysWithValues: ((try? context.fetch(downloadDescriptor)) ?? []).map { ($0.id, $0) })

        struct Resolved { var episode: Episode?; var show: Show? }
        var resolved = records.map { record in
            Resolved(
                episode: CatalogCache.episode(showId: record.showId, episodeId: record.id, in: context),
                show: CatalogCache.show(id: record.showId, in: context))
        }

        // Only the records CatalogCache didn't already answer hit the network, and every one of
        // those does so concurrently rather than one at a time.
        await withTaskGroup(of: (Int, Episode?, Show?).self) { group in
            for (index, record) in records.enumerated() where resolved[index].episode == nil || resolved[index].show == nil {
                let showId = record.showId
                let episodeId = record.id
                let needsEpisode = resolved[index].episode == nil
                let needsShow = resolved[index].show == nil
                group.addTask { [catalogClient] in
                    let episode = needsEpisode ? try? await catalogClient.getEpisode(showId: showId, episodeId: episodeId) : nil
                    let show = needsShow ? try? await catalogClient.getShow(id: showId) : nil
                    return (index, episode, show)
                }
            }
            for await (index, episode, show) in group {
                if let episode { resolved[index].episode = episode }
                if let show { resolved[index].show = show }
            }
        }

        let entries = zip(records, resolved).compactMap { record, resolved -> ContinueListeningEntry? in
            // An episode the network fallback also couldn't resolve (deleted from its feed, most
            // likely) is dropped rather than shown as a dead row with no title to display.
            guard let episode = resolved.episode else { return nil }
            return ContinueListeningEntry(
                episode: episode, show: resolved.show, positionSeconds: record.positionSeconds,
                downloadRecord: downloadRecords[record.id])
        }
        guard !entries.isEmpty else { return nil }

        let items = entries.map { entry -> CPListItem in
            let item = CPListItem(text: entry.episode.title, detailText: entry.show?.title)
            item.handler = { [weak self] _, completion in
                Task {
                    await self?.resumeContinueListening(entry)
                    completion()
                }
            }
            loadImage(for: item, urlString: entry.show?.artworkUrl)
            return item
        }
        return CPListSection(items: items, header: "Continue Listening", sectionIndexTitle: nil)
    }

    // Resumes an episode from Continue Listening directly, reusing the existing play() path with
    // a single-item PlaybackList — there's no "next in this cross-show list" to auto-advance
    // through the way a show's episode list or a playlist has, so unlike pushEpisodesList/
    // pushPlaylistDetail this list is never armed as PlaybackQueue's own snapshot.
    private func resumeContinueListening(_ entry: ContinueListeningEntry) async {
        // Cache-first (#761): the synced UserSettingsRecord answers the global fallback without a
        // network call. Awaits settingsSyncTask first (already in flight since didConnect, same as
        // loadSubscriptionsList's settled pass) so a fast tap right after connecting reads settled
        // settings rather than racing an empty/stale local store. There's no local mirror of
        // per-show ShowSettings (the phone app itself resolves those live too — see
        // playPlaylistItem's comment), so that one stays a network call, run concurrently with the
        // sync wait rather than after it.
        async let showSettings = try? settingsClient.getShowSettings(showId: entry.episode.showId)
        await settingsSyncTask?.value
        let user = Self.modelContainer.map(ModelContext.init).flatMap(Self.localUserSettings)
        let show = await showSettings
        let autoSkipIntroSeconds = TimeInterval(show?.autoSkipIntroSeconds ?? user?.autoSkipIntroSeconds ?? 0)
        let autoSkipOutroSeconds = TimeInterval(show?.autoSkipOutroSeconds ?? user?.autoSkipOutroSeconds ?? 0)
        let playbackSpeed = show?.playbackSpeed ?? user?.playbackSpeed ?? 1.0
        let smartSpeed = show?.smartSpeed ?? user?.smartSpeed ?? false
        let voiceBoost = show?.voiceBoost ?? user?.voiceBoost ?? false
        let trimSilence = show?.trimSilence ?? user?.trimSilence ?? false
        let volumeOffsetDb = show?.volumeOffsetDb ?? user?.volumeOffsetDb ?? 0

        let list = PlaybackList(
            source: .show(id: entry.episode.showId),
            items: [PlaybackQueue.QueueItem(showId: entry.episode.showId, episodeId: entry.episode.id)])

        play(
            episode: entry.episode, showId: entry.episode.showId, showTitle: entry.show?.title ?? "",
            showArtworkUrl: entry.show?.artworkUrl, startPosition: TimeInterval(entry.positionSeconds),
            downloadRecord: entry.downloadRecord, autoSkipIntroSeconds: autoSkipIntroSeconds,
            autoSkipOutroSeconds: autoSkipOutroSeconds, playbackSpeed: playbackSpeed, smartSpeed: smartSpeed,
            voiceBoost: voiceBoost, trimSilence: trimSilence, volumeOffsetDb: volumeOffsetDb, list: list)
    }

    private func subscriptionsSections(for subscriptions: [Subscription]) -> [CPListSection] {
        guard !subscriptions.isEmpty else {
            return [CPListSection(items: [CPListItem(text: "You haven't subscribed to any shows yet.", detailText: nil)])]
        }
        let items = subscriptions.map { subscription -> CPListItem in
            let item = CPListItem(text: subscription.showTitle, detailText: subscription.showAuthor)
            item.accessoryType = .disclosureIndicator
            item.handler = { [weak self] _, completion in
                Task {
                    await self?.pushEpisodesList(
                        showId: subscription.showId, showTitle: subscription.showTitle,
                        showArtworkUrl: subscription.showArtworkUrl)
                    completion()
                }
            }
            loadImage(for: item, urlString: subscription.showArtworkUrl)
            return item
        }
        return [CPListSection(items: items)]
    }

    // Cache-first (#758): paint instantly from the locally-synced PlaylistRecord store (kept
    // current by PlaylistSyncAdapter, the same store PlaylistsView reads) via
    // PlaylistSummary.list(from:), then await the playlist sync kicked off in didConnect (mirrors
    // loadSubscriptionsList's episodeSync/settingsSync wait) and repaint from the settled store.
    // CarPlay never makes its own playlist list network call now — replaces the old network-only
    // fetch (#641).
    private func loadPlaylistsList(into template: CPListTemplate, playlistSync: Task<Void, Never>) async {
        let context = Self.modelContainer.map(ModelContext.init)

        var paintedFromCache = false
        if let context {
            let cached = PlaylistSummary.local(in: context)
            if !cached.isEmpty {
                template.updateSections(playlistsSections(for: cached))
                paintedFromCache = true
            }
        }

        await playlistSync.value
        guard !Task.isCancelled else { return }

        guard let context else {
            guard !paintedFromCache else { return }
            template.updateSections(
                [CPListSection(items: [CPListItem(text: "Couldn't load your playlists.", detailText: nil)])])
            return
        }
        template.updateSections(playlistsSections(for: PlaylistSummary.local(in: context)))
    }

    private func playlistsSections(for playlists: [PlaylistSummary]) -> [CPListSection] {
        guard !playlists.isEmpty else {
            return [CPListSection(items: [CPListItem(text: "You haven't created any playlists yet.", detailText: nil)])]
        }
        let items = playlists.map { playlist -> CPListItem in
            let item = CPListItem(text: playlist.name, detailText: "\(playlist.itemCount) episode\(playlist.itemCount == 1 ? "" : "s")")
            item.accessoryType = .disclosureIndicator
            item.handler = { [weak self] _, completion in
                Task {
                    await self?.pushPlaylistDetail(playlistId: playlist.id, playlistName: playlist.name)
                    completion()
                }
            }
            return item
        }
        return [CPListSection(items: items)]
    }

    // Cache-first (#758): push instantly from the locally-synced PlaylistRecord via
    // PlaylistDetail.local(id:in:) (shared with PlaylistDetailView's own local placeholder), then
    // refresh from the network and update the same template's sections/title in place — mirrors
    // pushEpisodesList's cache-then-network shape. Still a live GET /api/playlists/{id} refresh
    // behind the cache paint (unlike the list screen, which is now sync-only): a dynamic
    // playlist's item set is server-recomputed, and PlaylistSyncAdapter doesn't push that
    // recomputation back down on its own.
    private func pushPlaylistDetail(playlistId: String, playlistName: String) async {
        let context = Self.modelContainer.map(ModelContext.init)

        var pushedTemplate: CPListTemplate?
        if let context, let local = PlaylistDetail.local(id: playlistId, in: context) {
            let template = playlistDetailTemplate(detail: local)
            interfaceController?.pushTemplate(template, animated: true, completion: nil)
            pushedTemplate = template
        }

        do {
            guard let detail = try await playlistClient.getPlaylistDetail(id: playlistId) else {
                // 404 — deleted server-side since the list was loaded.
                let sections = [CPListSection(items: [CPListItem(text: "This playlist no longer exists.", detailText: nil)])]
                if let pushedTemplate {
                    pushedTemplate.updateSections(sections)
                } else {
                    interfaceController?.pushTemplate(
                        CPListTemplate(title: playlistName, sections: sections), animated: true, completion: nil)
                }
                return
            }
            let freshTemplate = playlistDetailTemplate(detail: detail)
            if let pushedTemplate {
                // CPListTemplate.title is get-only after init — a rename since the cache-painted
                // pass (rare: only another device renaming this playlist mid-session) won't
                // retitle the pushed screen, same tradeoff pushEpisodesList accepts for showTitle.
                pushedTemplate.updateSections(freshTemplate.sections)
            } else {
                interfaceController?.pushTemplate(freshTemplate, animated: true, completion: nil)
            }
        } catch {
            // The cache already painted something useful — leave it up rather than clobbering it
            // with an error, same tolerance loadSubscriptionsList gives a stale-but-present cache.
            guard pushedTemplate == nil else { return }
            interfaceController?.pushTemplate(
                CPListTemplate(
                    title: playlistName,
                    sections: [CPListSection(items: [CPListItem(text: "Couldn't load this playlist.", detailText: nil)])]),
                animated: true, completion: nil)
        }
    }

    private func playlistDetailTemplate(detail: PlaylistDetail) -> CPListTemplate {
        guard !detail.items.isEmpty else {
            return CPListTemplate(
                title: detail.name,
                sections: [CPListSection(items: [CPListItem(text: "This playlist is empty.", detailText: nil)])])
        }

        // Snapshot of this playlist's order so a finished episode can auto-advance through it
        // (#629), mirroring PlaybackQueue.begin(playlistId:currentEpisodeId:) but built from the
        // detail this screen already has on hand rather than re-fetching it a second time.
        let list = PlaybackList(
            source: .playlist(id: detail.id, type: detail.type),
            items: detail.items.map { PlaybackQueue.QueueItem(showId: $0.showId, episodeId: $0.episodeId) })

        let items = detail.items.map { playlistItem -> CPListItem in
            let item = CPListItem(text: playlistItem.title ?? "(episode unavailable)", detailText: nil)
            item.handler = { [weak self] _, completion in
                Task {
                    await self?.playPlaylistItem(playlistItem, playlistId: detail.id, list: list)
                    completion()
                }
            }
            loadImage(for: item, urlString: playlistItem.artworkUrl)
            return item
        }

        return CPListTemplate(title: detail.name, sections: [CPListSection(items: items)])
    }

    // A playlist's items can span shows, unlike pushEpisodesList's single-show settingsTask, so
    // each item's episode/show/settings are resolved individually on tap rather than prefetched
    // for the whole list — mirrors PlaybackQueue.playItem's per-episode resolution.
    private func playPlaylistItem(_ playlistItem: PlaylistItemDetail, playlistId: String, list: PlaybackList) async {
        let context = Self.modelContainer.map(ModelContext.init)

        // Cache-first (#761): CatalogCache may already have this episode/show from browsing the
        // same show elsewhere in the app — only what's actually missing hits the network,
        // concurrently, mirroring continueListeningSection's resolution. There's no local mirror
        // of per-show ShowSettings anywhere in the app (EpisodeDetailView/ShowDetailView fetch it
        // live too), so that call stays live, but it's kicked off up front rather than after the
        // episode/show lookups.
        async let showSettings = try? settingsClient.getShowSettings(showId: playlistItem.showId)
        var episode = context.flatMap { CatalogCache.episode(showId: playlistItem.showId, episodeId: playlistItem.episodeId, in: $0) }
        var show = context.flatMap { CatalogCache.show(id: playlistItem.showId, in: $0) }
        if episode == nil || show == nil {
            let needsEpisode = episode == nil
            let needsShow = show == nil
            async let episodeResult = needsEpisode
                ? try? await catalogClient.getEpisode(showId: playlistItem.showId, episodeId: playlistItem.episodeId) : nil
            async let showResult = needsShow ? try? await catalogClient.getShow(id: playlistItem.showId) : nil
            let (fetchedEpisode, fetchedShow) = await (episodeResult, showResult)
            if let fetchedEpisode { episode = fetchedEpisode }
            if let fetchedShow { show = fetchedShow }
        }
        guard let episode else { return }

        // Same settingsSyncTask wait as resumeContinueListening, so a fast tap on a just-connected
        // session reads settled local settings rather than whatever was there before this session.
        await settingsSyncTask?.value
        let user = context.flatMap(Self.localUserSettings)
        let showSettingsResolved = await showSettings
        let autoSkipIntroSeconds = TimeInterval(showSettingsResolved?.autoSkipIntroSeconds ?? user?.autoSkipIntroSeconds ?? 0)
        let autoSkipOutroSeconds = TimeInterval(showSettingsResolved?.autoSkipOutroSeconds ?? user?.autoSkipOutroSeconds ?? 0)
        let playbackSpeed = showSettingsResolved?.playbackSpeed ?? user?.playbackSpeed ?? 1.0
        let smartSpeed = showSettingsResolved?.smartSpeed ?? user?.smartSpeed ?? false
        let voiceBoost = showSettingsResolved?.voiceBoost ?? user?.voiceBoost ?? false
        let trimSilence = showSettingsResolved?.trimSilence ?? user?.trimSilence ?? false
        let volumeOffsetDb = showSettingsResolved?.volumeOffsetDb ?? user?.volumeOffsetDb ?? 0

        var startPosition: TimeInterval = 0
        var downloadRecord: DownloadedEpisodeRecord?
        if let context {
            let episodeId = playlistItem.episodeId
            if let state = try? context.fetch(
                FetchDescriptor<EpisodeStateRecord>(predicate: #Predicate { $0.id == episodeId })
            ).first, !state.completed {
                startPosition = TimeInterval(state.positionSeconds)
            }
            downloadRecord = try? context.fetch(
                FetchDescriptor<DownloadedEpisodeRecord>(predicate: #Predicate { $0.id == episodeId })
            ).first
        }

        play(
            episode: episode, showId: playlistItem.showId, showTitle: show?.title ?? "",
            showArtworkUrl: playlistItem.artworkUrl ?? show?.artworkUrl, startPosition: startPosition,
            downloadRecord: downloadRecord, autoSkipIntroSeconds: autoSkipIntroSeconds,
            autoSkipOutroSeconds: autoSkipOutroSeconds, playbackSpeed: playbackSpeed, smartSpeed: smartSpeed,
            voiceBoost: voiceBoost, trimSilence: trimSilence, volumeOffsetDb: volumeOffsetDb, list: list, playlistId: playlistId)
    }

    // Cache-first (#637): push instantly from CatalogCache.episodes if it has anything for this
    // show, then refresh from the network and update the same template's sections in place — a
    // second CPListTemplate push would stack a duplicate screen instead of replacing this one.
    private func pushEpisodesList(showId: String, showTitle: String, showArtworkUrl: String?) async {
        let context = Self.modelContainer.map(ModelContext.init)

        // Same show-override-else-global settings EpisodeDetailView.loadPlaybackSettings()
        // resolves per episode — kicked off once here and shared by every row's tap handler
        // (whether built from the cache-painted list or the network-refreshed one), since every
        // episode from this show shares them.
        let settingsClient = self.settingsClient
        let settingsTask = Task { () -> (UserSettings?, ShowSettings?) in
            async let userSettings = try? settingsClient.getSettings()
            async let showSettings = try? settingsClient.getShowSettings(showId: showId)
            return await (userSettings, showSettings)
        }

        var pushedTemplate: CPListTemplate?
        if let context {
            let cachedEpisodes = CatalogCache.episodes(showId: showId, in: context)
            if !cachedEpisodes.isEmpty {
                let template = episodesTemplate(
                    episodes: cachedEpisodes, showId: showId, showTitle: showTitle, showArtworkUrl: showArtworkUrl,
                    context: context, settingsTask: settingsTask)
                interfaceController?.pushTemplate(template, animated: true, completion: nil)
                pushedTemplate = template
            }
        }

        // First page only — CarPlay's browse surface favors a short, scannable list over
        // ShowDetailView's "Load more" pagination, which needs a screen to tap through, not a
        // dashboard to glance at while driving.
        do {
            let page = try await catalogClient.getEpisodes(showId: showId, continuationToken: nil)
            if let context {
                CatalogCache.replaceEpisodes(showId: showId, page.items, continuationToken: page.continuationToken, in: context)
            }
            let freshTemplate = episodesTemplate(
                episodes: page.items, showId: showId, showTitle: showTitle, showArtworkUrl: showArtworkUrl,
                context: context, settingsTask: settingsTask)
            if let pushedTemplate {
                pushedTemplate.updateSections(freshTemplate.sections)
            } else {
                interfaceController?.pushTemplate(freshTemplate, animated: true, completion: nil)
            }
        } catch {
            guard pushedTemplate == nil else { return }
            let template = CPListTemplate(
                title: showTitle,
                sections: [CPListSection(items: [CPListItem(text: "Couldn't load episodes for this show.", detailText: nil)])])
            interfaceController?.pushTemplate(template, animated: true, completion: nil)
        }
    }

    private func episodesTemplate(
        episodes: [Episode], showId: String, showTitle: String, showArtworkUrl: String?, context: ModelContext?,
        settingsTask: Task<(UserSettings?, ShowSettings?), Never>
    ) -> CPListTemplate {
        let statuses: [String: EpisodeStatus]
        let positions: [String: Int]
        var downloadRecords: [String: DownloadedEpisodeRecord] = [:]
        var archived: Set<String> = []
        if let context {
            let episodeIds = Set(episodes.map(\.id))
            (statuses, positions, archived) = EpisodeStatus.statusAndPositionMaps(for: episodeIds, in: context)
            let downloadDescriptor = FetchDescriptor<DownloadedEpisodeRecord>(predicate: #Predicate { episodeIds.contains($0.id) })
            let records = (try? context.fetch(downloadDescriptor)) ?? []
            downloadRecords = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        } else {
            statuses = [:]
            positions = [:]
        }

        // Matches ShowDetailView's default "Unfinished" tab — hides played and archived
        // episodes so CarPlay's episode list follows the same convention as opening the show in
        // the iOS app, rather than always showing the show's full back catalogue.
        let episodes = EpisodeListFilter.apply(
            episodes: episodes, statuses: statuses, filter: .unfinished, sort: .newestFirst, archived: archived)

        // Snapshot of this browse page so a finished episode can auto-advance through it (#629),
        // the same way ShowDetailView arms PlaybackQueue from its own displayed list.
        let list = PlaybackList(
            source: .show(id: showId),
            items: episodes.map { PlaybackQueue.QueueItem(showId: showId, episodeId: $0.id) })

        let items = episodes.map { episode -> CPListItem in
            let status = statuses[episode.id] ?? .new
            let item = CPListItem(text: episode.title, detailText: Self.episodeDetailText(episode: episode, status: status))
            item.handler = { [weak self] _, completion in
                Task {
                    let (user, show) = await settingsTask.value
                    let autoSkipIntroSeconds = TimeInterval(show?.autoSkipIntroSeconds ?? user?.autoSkipIntroSeconds ?? 0)
                    let autoSkipOutroSeconds = TimeInterval(show?.autoSkipOutroSeconds ?? user?.autoSkipOutroSeconds ?? 0)
                    let playbackSpeed = show?.playbackSpeed ?? user?.playbackSpeed ?? 1.0
                    let smartSpeed = show?.smartSpeed ?? user?.smartSpeed ?? false
                    let voiceBoost = show?.voiceBoost ?? user?.voiceBoost ?? false
                    let trimSilence = show?.trimSilence ?? user?.trimSilence ?? false
                    let volumeOffsetDb = show?.volumeOffsetDb ?? user?.volumeOffsetDb ?? 0
                    self?.play(
                        episode: episode, showId: showId, showTitle: showTitle, showArtworkUrl: showArtworkUrl,
                        startPosition: TimeInterval(positions[episode.id] ?? 0), downloadRecord: downloadRecords[episode.id],
                        autoSkipIntroSeconds: autoSkipIntroSeconds, autoSkipOutroSeconds: autoSkipOutroSeconds,
                        playbackSpeed: playbackSpeed, smartSpeed: smartSpeed, voiceBoost: voiceBoost,
                        trimSilence: trimSilence, volumeOffsetDb: volumeOffsetDb, list: list)
                    completion()
                }
            }
            loadImage(for: item, urlString: showArtworkUrl)
            return item
        }

        return CPListTemplate(title: showTitle, sections: [CPListSection(items: items)])
    }

    private func play(
        episode: Episode, showId: String, showTitle: String, showArtworkUrl: String?, startPosition: TimeInterval,
        downloadRecord: DownloadedEpisodeRecord?, autoSkipIntroSeconds: TimeInterval, autoSkipOutroSeconds: TimeInterval,
        playbackSpeed: Float, smartSpeed: Bool, voiceBoost: Bool, trimSilence: Bool, volumeOffsetDb: Float = 0,
        list: PlaybackList, playlistId: String? = nil
    ) {
        // Prefers a completed local download over the remote URL, same as EpisodeDetailView —
        // driving is exactly the poor-connectivity case offline downloads exist for.
        guard let audioUrl = EpisodeDetailView.resolvedPlaybackURL(
            audioUrlString: episode.audioUrl, downloadRecord: downloadRecord,
            downloadsDirectory: DownloadManager.downloadsDirectory())
        else { return }

        // Re-selecting the episode already playing just brings up Now Playing rather than
        // restarting the AVPlayerItem from scratch (which a quick double-tap would otherwise do).
        if AudioPlayer.shared.currentURL != audioUrl {
            progressTrackingTask?.cancel()
            // Arms PlaybackQueue with this browse page's snapshot so finishing the episode honors
            // the resolved PlayNextBehavior, same as the phone UI (#629) — replacing whatever a
            // previous session (phone or CarPlay) had armed.
            PlaybackQueue.shared.begin(list: list, currentEpisodeId: episode.id)

            let episodeId = episode.id
            let duration = episode.duration
            AudioPlayer.shared.onDidFinishPlaying = { [weak self] finishedURL in
                guard finishedURL == audioUrl else { return }
                self?.progressTrackingTask?.cancel()
                self?.progressTrackingTask = nil
                Task {
                    let persisted = await Self.persist(
                        episodeId: episodeId, showId: showId, positionSeconds: Int(duration ?? 0), completed: true)
                    // Mirrors EpisodeDetailView.persist()'s auto-delete hook (#179/#532) — CarPlay's
                    // own persist() has no equivalent, so a natural finish here would otherwise
                    // never honor "delete after played" the way the phone UI does. Gated on the
                    // write actually committing — deleting a download or stripping a playlist entry
                    // for an episode the sync record never actually recorded as played would be
                    // wrong, and the download deletion can't be undone short of a re-download.
                    if persisted {
                        await Self.cleanupDownloadIfEligible(episodeId: episodeId)
                    }
                    await PlaybackQueue.shared.handleNaturalFinish(finishedEpisodeId: episodeId)
                }
            }

            AudioPlayer.shared.play(
                url: audioUrl, startPosition: startPosition,
                autoSkipIntroSeconds: autoSkipIntroSeconds, autoSkipOutroSeconds: autoSkipOutroSeconds,
                playbackSpeed: playbackSpeed, smartSpeed: smartSpeed, voiceBoost: voiceBoost, trimSilence: trimSilence,
                volumeOffsetDb: volumeOffsetDb,
                context: NowPlayingContext(showId: showId, episodeId: episode.id, playlistId: playlistId),
                metadata: NowPlayingMetadata(
                    title: episode.title, showTitle: showTitle, artworkURL: showArtworkUrl.flatMap(URL.init(string:))))

            // Refreshes the speed button's rendered label for this episode's resolved speed
            // (show override, or the global default) — otherwise it would keep showing whatever
            // the previously playing episode's speed was.
            updateNowPlayingActionButtons()

            // Mirrors EpisodeDetailView.startProgressTracking()'s periodic save so an episode
            // started from CarPlay resumes where it left off, and gets marked played on finish,
            // the same as one started from the phone.
            progressTrackingTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(20))
                    guard !Task.isCancelled, AudioPlayer.shared.currentURL == audioUrl else { return }
                    guard AudioPlayer.shared.isPlaying else { continue }
                    let positionSeconds = Int(AudioPlayer.shared.currentTime)
                    // Promotes this tick to completed once playback is within the near-end
                    // threshold of the episode's duration (#704) rather than always reporting false.
                    let completed = EpisodeProgress.isNearEnd(
                        positionSeconds: positionSeconds, duration: AudioPlayer.shared.duration,
                        thresholdSeconds: EpisodeProgress.nearEndThresholdSeconds)
                    await Self.persist(episodeId: episodeId, showId: showId, positionSeconds: positionSeconds, completed: completed)
                }
            }
        }

        // Most of CPNowPlayingTemplate's content (title, artwork, elapsed time, transport state)
        // comes for free from the MPNowPlayingInfoCenter/MPRemoteCommandCenter wiring AudioPlayer
        // already does for the lock screen — the Up Next button is wired once in didConnect (#640).
        interfaceController?.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
    }

    // Up Next screen (#640) — pushed from nowPlayingTemplateUpNextButtonTapped below. Titles
    // resolve cache-first via CatalogCache.episode, falling back to the network concurrently for
    // anything not cached, mirroring continueListeningSection's resolution.
    private func pushUpNextList() async {
        let queueItems = PlaybackQueue.shared.upNextItems
        guard !queueItems.isEmpty else {
            let template = CPListTemplate(
                title: "Up Next",
                sections: [CPListSection(items: [CPListItem(text: "Nothing queued up next.", detailText: nil)])])
            interfaceController?.pushTemplate(template, animated: true, completion: nil)
            return
        }

        let context = Self.modelContainer.map(ModelContext.init)
        var episodes: [Episode?] = queueItems.map { item in
            context.flatMap { CatalogCache.episode(showId: item.showId, episodeId: item.episodeId, in: $0) }
        }

        await withTaskGroup(of: (Int, Episode?).self) { group in
            for (index, item) in queueItems.enumerated() where episodes[index] == nil {
                let showId = item.showId
                let episodeId = item.episodeId
                group.addTask { [catalogClient] in
                    (index, try? await catalogClient.getEpisode(showId: showId, episodeId: episodeId))
                }
            }
            for await (index, episode) in group {
                episodes[index] = episode
            }
        }

        let items = zip(queueItems, episodes).map { queueItem, episode -> CPListItem in
            let item = CPListItem(text: episode?.title ?? "(episode unavailable)", detailText: nil)
            item.handler = { [weak self] _, completion in
                Task {
                    await PlaybackQueue.shared.playUpNextItem(queueItem)
                    // Pops this list back to the Now Playing screen it was pushed from, rather
                    // than leaving the user looking at a now-stale queue for the episode that just
                    // started playing.
                    self?.interfaceController?.popTemplate(animated: true, completion: nil)
                    completion()
                }
            }
            return item
        }

        let template = CPListTemplate(title: "Up Next", sections: [CPListSection(items: items)])
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    // Episode actions (#642) — CPListItem's real equivalent of the phone's EpisodeSwipeAction set
    // (Mark Played / Download / Add to Playlist), plus Playback Speed, each as its own button
    // directly on the Now Playing screen (see the didConnect comment on why: a single "More" menu
    // button hid every option behind an extra tap while driving). Rebuilt whenever the currently
    // playing episode or its speed changes so the speed button's rendered label stays current.
    // Acts on whatever AudioPlayer currently reports as playing — the only "this episode" CarPlay
    // has once the driver has left the browse list behind for Now Playing.
    private func updateNowPlayingActionButtons() {
        let speedButton = CPNowPlayingImageButton(image: Self.playbackSpeedButtonImage(for: AudioPlayer.shared.playbackSpeed)) {
            [weak self] _ in
            Task { await self?.cyclePlaybackSpeed() }
        }
        let markPlayedButton = CPNowPlayingImageButton(image: UIImage(systemName: "checkmark.circle") ?? UIImage()) {
            [weak self] _ in
            Task { await self?.markCurrentEpisodePlayed() }
        }
        let downloadButton = CPNowPlayingImageButton(image: UIImage(systemName: "arrow.down.circle") ?? UIImage()) {
            [weak self] _ in
            Task { await self?.downloadCurrentEpisode() }
        }
        let addToPlaylistButton = CPNowPlayingImageButton(image: UIImage(systemName: "text.badge.plus") ?? UIImage()) {
            [weak self] _ in
            Task { await self?.addCurrentEpisodeToPlaylist() }
        }
        CPNowPlayingTemplate.shared.updateNowPlayingButtons([speedButton, markPlayedButton, downloadButton, addToPlaylistButton])
    }

    // Renders the button's face as its own text ("1.5×"), the same value NowPlayingView's speed
    // pill shows on the phone — CPNowPlayingImageButton only takes a plain UIImage, with no title
    // label of its own, so a driver glancing at the button has nothing to read otherwise.
    private static func playbackSpeedButtonImage(for speed: Float) -> UIImage {
        let label = PlaybackSpeedOption(rawValue: speed)?.label
            ?? "\(speed.formatted(.number.precision(.fractionLength(0...2))))x"
        let size = CGSize(width: 64, height: 44)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 20, weight: .semibold),
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraph,
            ]
            (label as NSString).draw(
                in: CGRect(x: 0, y: (size.height - 24) / 2, width: size.width, height: 24), withAttributes: attributes)
        }.withRenderingMode(.alwaysOriginal)
    }

    // The pure "what's next" cycle, pulled out for unit testing (mirrors
    // EpisodeDetailView.cyclePlaybackSpeed / NowPlayingView.cyclePlaybackSpeed) — wraps back to the
    // slowest preset after the fastest. A value outside the presets (e.g. a synced override) starts
    // the cycle from the slowest preset rather than crashing on a missing match.
    nonisolated static func nextPlaybackSpeed(after current: Float) -> Float {
        let options = PlaybackSpeedOption.allCases.sorted { $0.rawValue < $1.rawValue }
        let currentIndex = options.firstIndex { $0.rawValue == current } ?? -1
        return options[(currentIndex + 1) % options.count].rawValue
    }

    // Applies the change live to whatever's playing (mirrors EpisodeDetailView/NowPlayingView:
    // CarPlay drives the same AudioPlayer) and best-effort saves it as the new global default —
    // simplified to a fire-and-forget save, without those screens' request-coalescing, since a
    // CarPlay button tap is far less rapid-fire than a slider drag.
    private func cyclePlaybackSpeed() async {
        let next = Self.nextPlaybackSpeed(after: AudioPlayer.shared.playbackSpeed)
        AudioPlayer.shared.setPlaybackSpeed(next)
        updateNowPlayingActionButtons()
        _ = try? await settingsClient.updatePlaybackSpeed(next)
    }

    private func markCurrentEpisodePlayed() async {
        guard let nowPlaying = AudioPlayer.shared.nowPlayingContext else { return }
        await markEpisodePlayed(showId: nowPlaying.showId, episodeId: nowPlaying.episodeId)
    }

    // Mirrors ShowDetailView.toggleCompleted's "mark played" branch: positionSeconds is the
    // episode's full duration, same as a natural finish would persist. Also mirrors that branch's
    // cleanup calls (#569/#532) — without these, an episode marked played from CarPlay's Now
    // Playing screen would strand itself in manual playlists and skip auto-delete-after-played.
    private func markEpisodePlayed(showId: String, episodeId: String) async {
        // Cache-first (#761): only the duration is needed here, and CatalogCache already has it
        // for any episode CarPlay could be marking played (that's how it got playing in the first
        // place) — the network fallback covers the rare case CatalogCache never saw it.
        let context = Self.modelContainer.map(ModelContext.init)
        let episode = await resolveEpisode(showId: showId, episodeId: episodeId, context: context)
        let persisted = await Self.persist(
            episodeId: episodeId, showId: showId, positionSeconds: Int(episode?.duration ?? 0), completed: true)
        // Gated on the write actually committing — see Self.persist's own doc comment.
        guard persisted else { return }
        await PlaylistCleanup.removeFromManualPlaylists(
            episodeId: episodeId, completed: true,
            playlistSyncEngine: Self.playlistSyncEngine, playlistClient: playlistClient)
        await Self.cleanupDownloadIfEligible(episodeId: episodeId)
        // #724: this path never patched the Shows/Subscriptions badge cache the way the phone UI's
        // mark-played toggles do, so an episode marked played from CarPlay's Now Playing screen
        // kept showing as unplayed there until the next full sync.
        if let context {
            CatalogCache.recordEpisodeStateChange(
                episodeId: episodeId, showId: showId, completed: true, positionSeconds: 0, in: context)
        }
    }

    private func downloadCurrentEpisode() async {
        guard let nowPlaying = AudioPlayer.shared.nowPlayingContext else { return }
        await downloadEpisode(showId: nowPlaying.showId, episodeId: nowPlaying.episodeId)
    }

    // Only starts the download — DownloadManager already runs in-process and shares its SwiftData
    // store with the phone UI, so a download kicked off here is picked up there (and vice versa)
    // automatically; see #642's own note on why consuming it needs no further work.
    private func downloadEpisode(showId: String, episodeId: String) async {
        // Cache-first (#761): same rationale as markEpisodePlayed — the episode CarPlay is
        // currently playing is already in CatalogCache from however it got there.
        let context = Self.modelContainer.map(ModelContext.init)
        if let episode = await resolveEpisode(showId: showId, episodeId: episodeId, context: context) {
            DownloadManager.shared.startDownload(episode: episode)
        }
    }

    // Shared cache-first lookup for markEpisodePlayed/downloadEpisode — both act on whatever
    // episode CarPlay currently reports as playing, which CatalogCache already has from however
    // playback got started; the network fallback only covers the rare episode CatalogCache never
    // saw (e.g. a natural-finish-triggered call after the app was reinstalled mid-session).
    private func resolveEpisode(showId: String, episodeId: String, context: ModelContext?) async -> Episode? {
        if let cached = context.flatMap({ CatalogCache.episode(showId: showId, episodeId: episodeId, in: $0) }) {
            return cached
        }
        return try? await catalogClient.getEpisode(showId: showId, episodeId: episodeId)
    }

    private func addCurrentEpisodeToPlaylist() async {
        guard let nowPlaying = AudioPlayer.shared.nowPlayingContext else { return }
        await pushPlaylistPicker(showId: nowPlaying.showId, episodeId: nowPlaying.episodeId)
    }

    // Mirrors AddToPlaylistSheet's phone reference implementation, simplified for a CPListTemplate
    // (#642) — same unfiltered playlist list (including dynamic playlists; the server is the
    // authority on whether adding to one is allowed), no inline "create new playlist" flow.
    // Cache-first (#761): sourced entirely from the locally-synced PlaylistRecord store — the same
    // one loadPlaylistsList paints the Playlists tab from, kept current by playlistSyncEngine —
    // rather than a live GET /api/playlists on every "Add to Playlist" tap, which could otherwise
    // leave this picker slow or blank on a fresh connect the same way the old Playlists tab was.
    // Awaits playlistSyncTask first (already in flight since didConnect, mirroring
    // loadPlaylistsList's own wait) so a fast tap right after connecting — e.g. straight from a
    // Continue Listening row, which paints before any sync is awaited — doesn't race an
    // empty/stale local store into a false "no playlists" screen.
    private func pushPlaylistPicker(showId: String, episodeId: String) async {
        await playlistSyncTask?.value
        guard let context = Self.modelContainer.map(ModelContext.init) else {
            let template = CPListTemplate(
                title: "Add to Playlist",
                sections: [CPListSection(items: [CPListItem(text: "Couldn't load your playlists.", detailText: nil)])])
            interfaceController?.pushTemplate(template, animated: true, completion: nil)
            return
        }
        let playlists = PlaylistSummary.local(in: context)

        guard !playlists.isEmpty else {
            let template = CPListTemplate(
                title: "Add to Playlist",
                sections: [CPListSection(items: [CPListItem(text: "You haven't created any playlists yet.", detailText: nil)])])
            interfaceController?.pushTemplate(template, animated: true, completion: nil)
            return
        }

        let items = playlists.map { playlist -> CPListItem in
            let item = CPListItem(text: playlist.name, detailText: nil)
            item.handler = { [weak self] _, completion in
                Task {
                    await self?.addEpisode(showId: showId, episodeId: episodeId, toPlaylistId: playlist.id)
                    completion()
                }
            }
            return item
        }
        let template = CPListTemplate(title: "Add to Playlist", sections: [CPListSection(items: items)])
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    private func addEpisode(showId: String, episodeId: String, toPlaylistId playlistId: String) async {
        try? await playlistClient.addItem(playlistId: playlistId, episodeId: episodeId, showId: showId)
        interfaceController?.popTemplate(animated: true, completion: nil)
    }

    // Returns whether the write actually committed — callers that follow a completed: true persist
    // with playlist/download cleanup (markEpisodePlayed, the natural-finish handler) must not strip
    // the episode from playlists or delete its download on the strength of a write that never
    // landed, since DownloadCleanup's delete is irreversible without a re-download.
    @discardableResult
    private static func persist(episodeId: String, showId: String, positionSeconds: Int, completed: Bool) async -> Bool {
        guard let syncEngine = episodeSyncEngine else { return false }
        do {
            try await syncEngine.write { context in
                let descriptor = FetchDescriptor<EpisodeStateRecord>(predicate: #Predicate { $0.id == episodeId })
                if let existing = try context.fetch(descriptor).first {
                    existing.showId = showId
                    existing.positionSeconds = positionSeconds
                    existing.completed = completed
                    existing.updatedAt = Date()
                    existing.autoPlayed = false
                    existing.isDirty = true
                } else {
                    context.insert(EpisodeStateRecord(
                        id: episodeId, showId: showId, positionSeconds: positionSeconds,
                        completed: completed, updatedAt: Date(), isDirty: true))
                }
            }
            return true
        } catch {
            // Mirrors EpisodeDetailView.persist()'s own assertionFailure — a silent try? here
            // would hide a lost playback position/completion write with nothing to point at.
            assertionFailure("Failed to persist episode state from CarPlay: \(episodeId): \(error)")
            return false
        }
    }

    // Mirrors EpisodeDetailView.persist()'s DownloadCleanup.deleteIfAutoDeleteEligible call, using
    // only the global rule — CarPlay has no per-show ShowSettings loaded the way EpisodeDetailView
    // does, so a per-show override can't be resolved here; this is best-effort like every other
    // cleanup call in this file.
    private static func cleanupDownloadIfEligible(episodeId: String) async {
        guard let context = modelContainer.map(ModelContext.init) else { return }
        let autoDeleteRule = localUserSettings(in: context)?.autoDeleteRule ?? .never
        DownloadCleanup.deleteIfAutoDeleteEligible(
            episodeId: episodeId, completed: true, autoDeleteRule: autoDeleteRule, in: context)
        await AppIconBadge.refresh(in: context)
    }

    // Best-effort artwork fetch for a list item — mirrors AudioPlayer.fetchArtworkIfNeeded's
    // "missing/failed artwork just leaves the row without an image" tolerance rather than
    // blocking the row from appearing. Checks imageCache first: the episodes list reuses the same
    // show artwork URL for every row, so without this every row would refetch it independently.
    // Falls back to the on-disk cache (#637) before hitting the network, so artwork survives
    // across CarPlay sessions instead of being re-downloaded from scratch on every fresh connect.
    private func loadImage(for item: CPListItem, urlString: String?) {
        guard let urlString, let url = URL(string: urlString) else { return }
        if let cached = imageCache[urlString] {
            item.setImage(cached)
            return
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // Resolved off the main thread — FileManager.createDirectory inside this is a
            // blocking stat/mkdir call that shouldn't run on main once per row.
            let diskCacheURL = Self.artworkDiskCacheFileURL(for: urlString)
            if let diskCacheURL, let data = try? Data(contentsOf: diskCacheURL), let image = UIImage(data: data) {
                DispatchQueue.main.async {
                    self?.imageCache[urlString] = image
                    item.setImage(image)
                }
                return
            }
            URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                guard let data, let image = UIImage(data: data) else { return }
                if let diskCacheURL {
                    try? data.write(to: diskCacheURL, options: .atomic)
                }
                DispatchQueue.main.async {
                    self?.imageCache[urlString] = image
                    item.setImage(image)
                }
            }.resume()
        }
    }

    // Keyed by a SHA256 of the URL string rather than the URL itself — Swift's String.hashValue
    // is randomized per process launch, so it can't be used to name a file that needs to resolve
    // to the same path across CarPlay sessions.
    private nonisolated static func artworkDiskCacheFileURL(for urlString: String) -> URL? {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let directory = base.appendingPathComponent("CarPlayArtwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let digest = SHA256.hash(data: Data(urlString.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest)
    }

    // Pulled out as a pure function so the row-building logic is unit-testable without a real
    // CPInterfaceController (which only exists once actually connected to CarPlay/its simulator).
    // nonisolated (mirroring EpisodeDetailView.resolvedPlaybackURL) since it touches no
    // actor-isolated state, so tests can call it from a plain, non-MainActor context.
    nonisolated static func episodeDetailText(episode: Episode, status: EpisodeStatus) -> String {
        [episode.duration.map(EpisodeFormatting.formatDuration), status.label]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}

// #640: CarPlay reports the Now Playing screen's Up Next button tap through this observer
// protocol rather than a closure property — added/removed in didConnect/didDisconnect above.
extension CarPlaySceneDelegate: @preconcurrency CPNowPlayingTemplateObserver {
    func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        Task { await pushUpNextList() }
    }
}
