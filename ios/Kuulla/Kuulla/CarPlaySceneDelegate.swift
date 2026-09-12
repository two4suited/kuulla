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
        interfaceController.setRootTemplate(Self.placeholderRootTemplate, animated: false, completion: nil)
        loadTask = Task { await loadSubscriptionsList() }
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

    private static var placeholderRootTemplate: CPListTemplate {
        CPListTemplate(title: "Kuulla", sections: [])
    }

    // Cache-first (#637): paint instantly from CatalogCache if it has anything for this show,
    // then refresh from the network behind it — same pattern as LibraryView/ShowDetailView.
    private func loadSubscriptionsList() async {
        let context = Self.modelContainer.map(ModelContext.init)

        var paintedFromCache = false
        if let context {
            let cached = Self.sortedSubscriptions(CatalogCache.subscriptions(in: context))
            if !cached.isEmpty {
                interfaceController?.setRootTemplate(subscriptionsTemplate(for: cached), animated: false, completion: nil)
                paintedFromCache = true
            }
        }

        do {
            let subscriptions = Self.sortedSubscriptions(try await subscriptionClient.getSubscriptions())
            if let context {
                CatalogCache.replaceSubscriptions(subscriptions, in: context)
            }
            interfaceController?.setRootTemplate(subscriptionsTemplate(for: subscriptions), animated: false, completion: nil)
        } catch {
            // The cache already painted something useful — leave it up rather than clobbering it
            // with an error, the same tolerance ShowDetailView.readLocalShow() gives a stale but
            // present cache when its own network follow-up fails.
            guard !paintedFromCache else { return }
            let template = CPListTemplate(
                title: "Kuulla",
                sections: [CPListSection(items: [CPListItem(text: "Couldn't load your subscriptions.", detailText: nil)])])
            interfaceController?.setRootTemplate(template, animated: false, completion: nil)
        }
    }

    private func subscriptionsTemplate(for subscriptions: [Subscription]) -> CPListTemplate {
        guard !subscriptions.isEmpty else {
            return CPListTemplate(
                title: "Kuulla",
                sections: [CPListSection(items: [CPListItem(text: "You haven't subscribed to any shows yet.", detailText: nil)])])
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
        return CPListTemplate(title: "Kuulla", sections: [CPListSection(items: items)])
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
        playbackSpeed: Float, smartSpeed: Bool, list: PlaybackList
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
                context: NowPlayingContext(showId: showId, episodeId: episode.id, playlistId: nil),
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

    // Pulled out as pure functions so the row-building logic is unit-testable without a real
    // CPInterfaceController (which only exists once actually connected to CarPlay/its simulator).
    // nonisolated (mirroring EpisodeDetailView.resolvedPlaybackURL) since they touch no
    // actor-isolated state, so tests can call them from a plain, non-MainActor context.
    nonisolated static func sortedSubscriptions(_ subscriptions: [Subscription]) -> [Subscription] {
        subscriptions.sorted { $0.showTitle.localizedCaseInsensitiveCompare($1.showTitle) == .orderedAscending }
    }

    nonisolated static func episodeDetailText(episode: Episode, status: EpisodeStatus) -> String {
        [episode.duration.map(EpisodeFormatting.formatDuration), status.label]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}
