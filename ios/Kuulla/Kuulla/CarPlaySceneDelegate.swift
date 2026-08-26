import CarPlay
import SwiftData
import UIKit

// Connects/tears down the CPInterfaceController for CarPlay's template scene, and drives the
// browse UI: subscriptions -> episodes -> Now Playing. Reuses the same clients/state as the
// phone UI (SubscriptionClient, PodcastCatalogClient, EpisodeStatus) rather than hand-rolling
// CarPlay-specific data access.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    // Set once by KuullaApp.init(), mirroring DownloadManager.shared.configure(modelContainer:) —
    // CarPlay's scene delegate is instantiated by UIKit, not SwiftUI, so it has no @Environment
    // to read the app's ModelContainer from.
    static var modelContainer: ModelContainer?

    var interfaceController: CPInterfaceController?

    private let subscriptionClient = SubscriptionClient()
    private let catalogClient = PodcastCatalogClient()

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
    }

    private static var placeholderRootTemplate: CPListTemplate {
        CPListTemplate(title: "Kuulla", sections: [])
    }

    private func loadSubscriptionsList() async {
        let subscriptions = Self.sortedSubscriptions((try? await subscriptionClient.getSubscriptions()) ?? [])

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

        let template = CPListTemplate(title: "Kuulla", sections: [CPListSection(items: items)])
        interfaceController?.setRootTemplate(template, animated: false, completion: nil)
    }

    private func pushEpisodesList(showId: String, showTitle: String, showArtworkUrl: String?) async {
        // First page only — CarPlay's browse surface favors a short, scannable list over
        // ShowDetailView's "Load more" pagination, which needs a screen to tap through, not a
        // dashboard to glance at while driving.
        let episodes = (try? await catalogClient.getEpisodes(showId: showId, continuationToken: nil))?.items ?? []

        let statuses: [String: EpisodeStatus]
        let positions: [String: Int]
        if let modelContainer = Self.modelContainer {
            let context = ModelContext(modelContainer)
            (statuses, positions, _) = EpisodeStatus.statusAndPositionMaps(for: Set(episodes.map(\.id)), in: context)
        } else {
            statuses = [:]
            positions = [:]
        }

        let items = episodes.map { episode -> CPListItem in
            let status = statuses[episode.id] ?? .new
            let item = CPListItem(text: episode.title, detailText: Self.episodeDetailText(episode: episode, status: status))
            item.handler = { [weak self] _, completion in
                self?.play(
                    episode: episode, showTitle: showTitle, showArtworkUrl: showArtworkUrl,
                    startPosition: TimeInterval(positions[episode.id] ?? 0))
                completion()
            }
            loadImage(for: item, urlString: showArtworkUrl)
            return item
        }

        let template = CPListTemplate(title: showTitle, sections: [CPListSection(items: items)])
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    private func play(episode: Episode, showTitle: String, showArtworkUrl: String?, startPosition: TimeInterval) {
        guard let audioUrl = URL(string: episode.audioUrl) else { return }
        AudioPlayer.shared.play(
            url: audioUrl, startPosition: startPosition,
            metadata: NowPlayingMetadata(
                title: episode.title, showTitle: showTitle, artworkURL: showArtworkUrl.flatMap(URL.init(string:))))
        // Most of CPNowPlayingTemplate's content (title, artwork, elapsed time, transport state)
        // comes for free from the MPNowPlayingInfoCenter/MPRemoteCommandCenter wiring AudioPlayer
        // already does for the lock screen — button configuration is #118's job.
        interfaceController?.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
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
