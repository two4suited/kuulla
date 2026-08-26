import CarPlay
import SwiftData
import UIKit

// Connects/tears down the CPInterfaceController for CarPlay's template scene, and drives the
// browse UI: subscriptions -> episodes -> Now Playing. Reuses the same clients/state as the
// phone UI (SubscriptionClient, PodcastCatalogClient, EpisodeStatus, EpisodeDetailView's
// resolvedPlaybackURL) rather than hand-rolling CarPlay-specific data access or a second,
// divergent playback-progress path.
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

    // Owned by this delegate (not AudioPlayer, which has no view-lifecycle concept of its own) so
    // disconnecting from CarPlay stops the periodic saves rather than leaking a Task that keeps
    // writing after there's no CarPlay session left to have driven them.
    private var progressTrackingTask: Task<Void, Never>?

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        interfaceController.setRootTemplate(Self.placeholderRootTemplate, animated: false, completion: nil)
        Task { await loadSubscriptionsList() }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        self.interfaceController = nil
        progressTrackingTask?.cancel()
        progressTrackingTask = nil
    }

    private static var placeholderRootTemplate: CPListTemplate {
        CPListTemplate(title: "Kuulla", sections: [])
    }

    private func loadSubscriptionsList() async {
        let template: CPListTemplate
        do {
            let subscriptions = Self.sortedSubscriptions(try await subscriptionClient.getSubscriptions())
            if subscriptions.isEmpty {
                template = CPListTemplate(
                    title: "Kuulla",
                    sections: [CPListSection(items: [CPListItem(text: "You haven't subscribed to any shows yet.", detailText: nil)])])
            } else {
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
                template = CPListTemplate(title: "Kuulla", sections: [CPListSection(items: items)])
            }
        } catch {
            template = CPListTemplate(
                title: "Kuulla",
                sections: [CPListSection(items: [CPListItem(text: "Couldn't load your subscriptions.", detailText: nil)])])
        }
        interfaceController?.setRootTemplate(template, animated: false, completion: nil)
    }

    private func pushEpisodesList(showId: String, showTitle: String, showArtworkUrl: String?) async {
        // First page only — CarPlay's browse surface favors a short, scannable list over
        // ShowDetailView's "Load more" pagination, which needs a screen to tap through, not a
        // dashboard to glance at while driving.
        async let episodesResult = catalogClient.getEpisodes(showId: showId, continuationToken: nil)
        // Same show-override-else-global settings EpisodeDetailView.loadPlaybackSettings() resolves
        // per episode — fetched once here since every episode from this show shares them.
        async let userSettings = try? settingsClient.getSettings()
        async let showSettings = try? settingsClient.getShowSettings(showId: showId)

        let episodes: [Episode]
        do {
            episodes = try await episodesResult.items
        } catch {
            let template = CPListTemplate(
                title: showTitle,
                sections: [CPListSection(items: [CPListItem(text: "Couldn't load episodes for this show.", detailText: nil)])])
            interfaceController?.pushTemplate(template, animated: true, completion: nil)
            return
        }

        let (user, show) = await (userSettings, showSettings)
        let autoSkipIntroSeconds = TimeInterval(show?.autoSkipIntroSeconds ?? user?.autoSkipIntroSeconds ?? 0)
        let autoSkipOutroSeconds = TimeInterval(show?.autoSkipOutroSeconds ?? user?.autoSkipOutroSeconds ?? 0)
        let playbackSpeed = show?.playbackSpeed ?? user?.playbackSpeed ?? 1.0
        let smartSpeed = show?.smartSpeed ?? user?.smartSpeed ?? false

        let statuses: [String: EpisodeStatus]
        let positions: [String: Int]
        var downloadRecords: [String: DownloadedEpisodeRecord] = [:]
        if let modelContainer = Self.modelContainer {
            let context = ModelContext(modelContainer)
            let episodeIds = Set(episodes.map(\.id))
            (statuses, positions, _) = EpisodeStatus.statusAndPositionMaps(for: episodeIds, in: context)
            let downloadDescriptor = FetchDescriptor<DownloadedEpisodeRecord>(predicate: #Predicate { episodeIds.contains($0.id) })
            let records = (try? context.fetch(downloadDescriptor)) ?? []
            downloadRecords = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        } else {
            statuses = [:]
            positions = [:]
        }

        let items = episodes.map { episode -> CPListItem in
            let status = statuses[episode.id] ?? .new
            let item = CPListItem(text: episode.title, detailText: Self.episodeDetailText(episode: episode, status: status))
            item.handler = { [weak self] _, completion in
                self?.play(
                    episode: episode, showId: showId, showTitle: showTitle, showArtworkUrl: showArtworkUrl,
                    startPosition: TimeInterval(positions[episode.id] ?? 0), downloadRecord: downloadRecords[episode.id],
                    autoSkipIntroSeconds: autoSkipIntroSeconds, autoSkipOutroSeconds: autoSkipOutroSeconds,
                    playbackSpeed: playbackSpeed, smartSpeed: smartSpeed)
                completion()
            }
            loadImage(for: item, urlString: showArtworkUrl)
            return item
        }

        let template = CPListTemplate(title: showTitle, sections: [CPListSection(items: items)])
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    private func play(
        episode: Episode, showId: String, showTitle: String, showArtworkUrl: String?, startPosition: TimeInterval,
        downloadRecord: DownloadedEpisodeRecord?, autoSkipIntroSeconds: TimeInterval, autoSkipOutroSeconds: TimeInterval,
        playbackSpeed: Float, smartSpeed: Bool
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

            let episodeId = episode.id
            let duration = episode.duration
            AudioPlayer.shared.onDidFinishPlaying = { [weak self] finishedURL in
                guard finishedURL == audioUrl else { return }
                self?.progressTrackingTask?.cancel()
                self?.progressTrackingTask = nil
                Task { await Self.persist(episodeId: episodeId, showId: showId, positionSeconds: Int(duration ?? 0), completed: true) }
            }

            AudioPlayer.shared.play(
                url: audioUrl, startPosition: startPosition,
                autoSkipIntroSeconds: autoSkipIntroSeconds, autoSkipOutroSeconds: autoSkipOutroSeconds,
                playbackSpeed: playbackSpeed, smartSpeed: smartSpeed,
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
        try? await syncEngine.write { context in
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
    }

    // Best-effort artwork fetch for a list item — mirrors AudioPlayer.fetchArtworkIfNeeded's
    // "missing/failed artwork just leaves the row without an image" tolerance rather than
    // blocking the row from appearing.
    private func loadImage(for item: CPListItem, urlString: String?) {
        guard let urlString, let url = URL(string: urlString) else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data, let image = UIImage(data: data) else { return }
            DispatchQueue.main.async {
                item.setImage(image)
            }
        }.resume()
    }

    // Pulled out as pure functions so the row-building logic is unit-testable without a real
    // CPInterfaceController (which only exists once actually connected to CarPlay/its simulator).
    static func sortedSubscriptions(_ subscriptions: [Subscription]) -> [Subscription] {
        subscriptions.sorted { $0.showTitle.localizedCaseInsensitiveCompare($1.showTitle) == .orderedAscending }
    }

    static func episodeDetailText(episode: Episode, status: EpisodeStatus) -> String {
        [episode.duration.map(EpisodeFormatting.formatDuration), status.label]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}
