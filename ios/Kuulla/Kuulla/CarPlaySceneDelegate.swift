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

        loadTask = Task {
            async let subscriptions: Void = loadSubscriptionsList(into: showsTemplate)
            async let playlists: Void = loadPlaylistsList(into: playlistsTemplate)
            _ = await (subscriptions, playlists)
        }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        self.interfaceController = nil
        loadTask?.cancel()
        loadTask = nil
        progressTrackingTask?.cancel()
        progressTrackingTask = nil
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
    private func loadSubscriptionsList(into template: CPListTemplate) async {
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
                let cached = sortedSubscriptions(
                    cachedSubscriptions, by: localSettings?.subscriptionSortOrder ?? .title,
                    manualOrder: localSettings?.subscriptionManualOrder ?? [])
                template.updateSections([continueListening].compactMap { $0 } + subscriptionsSections(for: cached))
                paintedFromCache = true
            }
        }

        do {
            async let subscriptionsResult = subscriptionClient.getSubscriptions()
            async let settingsResult = try? settingsClient.getSettings()
            let subscriptions = try await subscriptionsResult
            let settings = await settingsResult
            if let context {
                CatalogCache.replaceSubscriptions(subscriptions, in: context)
            }
            let sorted = sortedSubscriptions(
                subscriptions, by: settings?.subscriptionSortOrder ?? .title,
                manualOrder: settings?.subscriptionManualOrder ?? [])
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
        async let userSettings = try? settingsClient.getSettings()
        async let showSettings = try? settingsClient.getShowSettings(showId: entry.episode.showId)
        let (user, show) = await (userSettings, showSettings)
        let autoSkipIntroSeconds = TimeInterval(show?.autoSkipIntroSeconds ?? user?.autoSkipIntroSeconds ?? 0)
        let autoSkipOutroSeconds = TimeInterval(show?.autoSkipOutroSeconds ?? user?.autoSkipOutroSeconds ?? 0)
        let playbackSpeed = show?.playbackSpeed ?? user?.playbackSpeed ?? 1.0
        let smartSpeed = show?.smartSpeed ?? user?.smartSpeed ?? false

        let list = PlaybackList(
            source: .show(id: entry.episode.showId),
            items: [PlaybackQueue.QueueItem(showId: entry.episode.showId, episodeId: entry.episode.id)])

        play(
            episode: entry.episode, showId: entry.episode.showId, showTitle: entry.show?.title ?? "",
            showArtworkUrl: entry.show?.artworkUrl, startPosition: TimeInterval(entry.positionSeconds),
            downloadRecord: entry.downloadRecord, autoSkipIntroSeconds: autoSkipIntroSeconds,
            autoSkipOutroSeconds: autoSkipOutroSeconds, playbackSpeed: playbackSpeed, smartSpeed: smartSpeed, list: list)
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

    // Network-only (#641) — playlists have no on-device cache the way CatalogCache mirrors
    // subscriptions/episodes, so this is a plain fetch-then-render like pushEpisodesList's
    // network refresh half, without a cache-painted first pass.
    private func loadPlaylistsList(into template: CPListTemplate) async {
        do {
            let playlists = try await playlistClient.getPlaylists()
            template.updateSections(playlistsSections(for: playlists))
        } catch {
            template.updateSections(
                [CPListSection(items: [CPListItem(text: "Couldn't load your playlists.", detailText: nil)])])
        }
    }

    private func playlistsSections(for playlists: [Playlist]) -> [CPListSection] {
        guard !playlists.isEmpty else {
            return [CPListSection(items: [CPListItem(text: "You haven't created any playlists yet.", detailText: nil)])]
        }
        let items = playlists.map { playlist -> CPListItem in
            let episodeCount = playlist.items.count
            let item = CPListItem(text: playlist.name, detailText: "\(episodeCount) episode\(episodeCount == 1 ? "" : "s")")
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

    // Mirrors PlaylistDetailView's phone reference implementation: GET /api/playlists/{id}
    // resolves each item's title/artwork server-side, no separate per-episode fetch needed just
    // to render the row.
    private func pushPlaylistDetail(playlistId: String, playlistName: String) async {
        let detail: PlaylistDetail?
        do {
            detail = try await playlistClient.getPlaylistDetail(id: playlistId)
        } catch {
            let template = CPListTemplate(
                title: playlistName,
                sections: [CPListSection(items: [CPListItem(text: "Couldn't load this playlist.", detailText: nil)])])
            interfaceController?.pushTemplate(template, animated: true, completion: nil)
            return
        }

        guard let detail else {
            // 404 — deleted server-side since the list was loaded.
            let template = CPListTemplate(
                title: playlistName,
                sections: [CPListSection(items: [CPListItem(text: "This playlist no longer exists.", detailText: nil)])])
            interfaceController?.pushTemplate(template, animated: true, completion: nil)
            return
        }

        guard !detail.items.isEmpty else {
            let template = CPListTemplate(
                title: detail.name,
                sections: [CPListSection(items: [CPListItem(text: "This playlist is empty.", detailText: nil)])])
            interfaceController?.pushTemplate(template, animated: true, completion: nil)
            return
        }

        // Snapshot of this playlist's order so a finished episode can auto-advance through it
        // (#629), mirroring PlaybackQueue.begin(playlistId:currentEpisodeId:) but built from the
        // detail this screen already has on hand rather than re-fetching it a second time.
        let list = PlaybackList(
            source: .playlist(id: playlistId, type: detail.type),
            items: detail.items.map { PlaybackQueue.QueueItem(showId: $0.showId, episodeId: $0.episodeId) })

        let items = detail.items.map { playlistItem -> CPListItem in
            let item = CPListItem(text: playlistItem.title ?? "(episode unavailable)", detailText: nil)
            item.handler = { [weak self] _, completion in
                Task {
                    await self?.playPlaylistItem(playlistItem, playlistId: playlistId, list: list)
                    completion()
                }
            }
            loadImage(for: item, urlString: playlistItem.artworkUrl)
            return item
        }

        let template = CPListTemplate(title: detail.name, sections: [CPListSection(items: items)])
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    // A playlist's items can span shows, unlike pushEpisodesList's single-show settingsTask, so
    // each item's episode/show/settings are resolved individually on tap rather than prefetched
    // for the whole list — mirrors PlaybackQueue.playItem's per-episode resolution.
    private func playPlaylistItem(_ playlistItem: PlaylistItemDetail, playlistId: String, list: PlaybackList) async {
        async let episodeResult = try? catalogClient.getEpisode(showId: playlistItem.showId, episodeId: playlistItem.episodeId)
        async let showResult = try? catalogClient.getShow(id: playlistItem.showId)
        async let userSettings = try? settingsClient.getSettings()
        async let showSettings = try? settingsClient.getShowSettings(showId: playlistItem.showId)

        guard let episode = await episodeResult else { return }
        let show = await showResult
        let (user, showSettingsResolved) = await (userSettings, showSettings)
        let autoSkipIntroSeconds = TimeInterval(showSettingsResolved?.autoSkipIntroSeconds ?? user?.autoSkipIntroSeconds ?? 0)
        let autoSkipOutroSeconds = TimeInterval(showSettingsResolved?.autoSkipOutroSeconds ?? user?.autoSkipOutroSeconds ?? 0)
        let playbackSpeed = showSettingsResolved?.playbackSpeed ?? user?.playbackSpeed ?? 1.0
        let smartSpeed = showSettingsResolved?.smartSpeed ?? user?.smartSpeed ?? false

        var startPosition: TimeInterval = 0
        var downloadRecord: DownloadedEpisodeRecord?
        if let context = Self.modelContainer.map(ModelContext.init) {
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
            list: list, playlistId: playlistId)
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
        if let context {
            let episodeIds = Set(episodes.map(\.id))
            (statuses, positions, _) = EpisodeStatus.statusAndPositionMaps(for: episodeIds, in: context)
            let downloadDescriptor = FetchDescriptor<DownloadedEpisodeRecord>(predicate: #Predicate { episodeIds.contains($0.id) })
            let records = (try? context.fetch(downloadDescriptor)) ?? []
            downloadRecords = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        } else {
            statuses = [:]
            positions = [:]
        }

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
                    self?.play(
                        episode: episode, showId: showId, showTitle: showTitle, showArtworkUrl: showArtworkUrl,
                        startPosition: TimeInterval(positions[episode.id] ?? 0), downloadRecord: downloadRecords[episode.id],
                        autoSkipIntroSeconds: autoSkipIntroSeconds, autoSkipOutroSeconds: autoSkipOutroSeconds,
                        playbackSpeed: playbackSpeed, smartSpeed: smartSpeed, list: list)
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
        playbackSpeed: Float, smartSpeed: Bool, list: PlaybackList, playlistId: String? = nil
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
                    await Self.persist(episodeId: episodeId, showId: showId, positionSeconds: Int(duration ?? 0), completed: true)
                    await PlaybackQueue.shared.handleNaturalFinish(finishedEpisodeId: episodeId)
                }
            }

            AudioPlayer.shared.play(
                url: audioUrl, startPosition: startPosition,
                autoSkipIntroSeconds: autoSkipIntroSeconds, autoSkipOutroSeconds: autoSkipOutroSeconds,
                playbackSpeed: playbackSpeed, smartSpeed: smartSpeed,
                context: NowPlayingContext(showId: showId, episodeId: episode.id, playlistId: playlistId),
                metadata: NowPlayingMetadata(
                    title: episode.title, showTitle: showTitle, artworkURL: showArtworkUrl.flatMap(URL.init(string:))))

            // Mirrors EpisodeDetailView.startProgressTracking()'s periodic save so an episode
            // started from CarPlay resumes where it left off, and gets marked played on finish,
            // the same as one started from the phone.
            progressTrackingTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(20))
                    guard !Task.isCancelled, AudioPlayer.shared.currentURL == audioUrl else { return }
                    guard AudioPlayer.shared.isPlaying else { continue }
                    await Self.persist(episodeId: episodeId, showId: showId, positionSeconds: Int(AudioPlayer.shared.currentTime), completed: false)
                }
            }
        }

        // Most of CPNowPlayingTemplate's content (title, artwork, elapsed time, transport state)
        // comes for free from the MPNowPlayingInfoCenter/MPRemoteCommandCenter wiring AudioPlayer
        // already does for the lock screen — button configuration is #118's job.
        interfaceController?.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
    }

    private static func persist(episodeId: String, showId: String, positionSeconds: Int, completed: Bool) async {
        guard let syncEngine = episodeSyncEngine else { return }
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
        } catch {
            // Mirrors EpisodeDetailView.persist()'s own assertionFailure — a silent try? here
            // would hide a lost playback position/completion write with nothing to point at.
            assertionFailure("Failed to persist episode state from CarPlay: \(episodeId): \(error)")
        }
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
    private static func artworkDiskCacheFileURL(for urlString: String) -> URL? {
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
