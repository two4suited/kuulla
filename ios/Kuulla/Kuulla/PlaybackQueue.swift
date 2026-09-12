import Foundation
import Observation
import SwiftData

// Overcast-style auto-advance for manual playlists and the "Up Next" queue (#532).
//
// A single shared instance, mirroring AudioPlayer.shared: a playback session — and therefore the
// notion of "what just finished" and "what plays next" — outlives the EpisodeDetailView that
// started it, and CarPlay drives the very same AudioPlayer. Whoever starts playback of a manual
// playlist item arms the queue with begin(); the AudioPlayer.onDidFinishPlaying handlers call
// handleNaturalFinish() once the finished episode's completion is persisted, which removes that
// episode from the playlist server-side and starts the next item — or stops at the end.
//
// Dynamic playlists are deliberately excluded: their items are server-computed from rules and not
// editable in place, so there's nothing to "remove" and no stable running order to advance
// through. begin() disarms itself if the playlist turns out to be dynamic.
@MainActor
@Observable
final class PlaybackQueue {
    static let shared = PlaybackQueue()

    // Set once by KuullaApp.init(), mirroring CarPlaySceneDelegate's statics — PlaybackQueue is a
    // plain shared object instantiated outside SwiftUI, with no @Environment to read the app's
    // container / sync engine from.
    static var modelContainer: ModelContainer?
    static var episodeSyncEngine: SyncEngine<EpisodeSyncAdapter>?

    // The manual playlist the current session belongs to, plus an ordered snapshot of its items
    // taken when the session began — so "what's next" needs no re-fetch and tolerates the server
    // list shifting underneath. nil / [] whenever playback didn't start from a manual playlist.
    private(set) var playlistId: String?
    private var orderedItems: [QueueItem] = []
    // The episode currently playing as a queue item — guards a stale begin() (from a playlist
    // screen the user opened then backed out of without pressing Play) against advancing when
    // some unrelated episode later finishes.
    private(set) var currentEpisodeId: String?

    private var progressTrackingTask: Task<Void, Never>?

    private let playlistClient: PlaylistClient
    private let catalogClient: PodcastCatalogClient
    private let settingsClient: SettingsClient

    init(
        playlistClient: PlaylistClient = PlaylistClient(),
        catalogClient: PodcastCatalogClient = PodcastCatalogClient(),
        settingsClient: SettingsClient = SettingsClient()
    ) {
        self.playlistClient = playlistClient
        self.catalogClient = catalogClient
        self.settingsClient = settingsClient
    }

    struct QueueItem: Equatable {
        let showId: String
        let episodeId: String
    }

    // The one piece of pure decision logic, pulled out for unit testing (mirrors
    // AudioPlayer.shouldTriggerOutroSkip / EpisodeDetailView.resolvedPlaybackURL): the item that
    // should start after `finishedEpisodeId`, or nil at the end of the queue — or if the finished
    // episode isn't in the snapshot at all (a reorder/removal race), which is likewise treated as
    // "stop" rather than guessing.
    nonisolated static func nextItem(after finishedEpisodeId: String, in items: [QueueItem]) -> QueueItem? {
        guard let index = items.firstIndex(where: { $0.episodeId == finishedEpisodeId }),
              index + 1 < items.count
        else { return nil }
        return items[index + 1]
    }

    // Armed by EpisodeDetailView when it starts playback of an episode reached from a manual
    // playlist. Fetches the ordered item list once so finish handling knows the running order.
    func begin(playlistId: String, currentEpisodeId: String) async {
        self.playlistId = playlistId
        self.currentEpisodeId = currentEpisodeId
        self.orderedItems = []
        // A fresh session is taking over playback (EpisodeDetailView's Play, or a re-arm on a
        // different playlist item) — the queue's own periodic-save loop for the previously
        // auto-advanced episode is now stale.
        progressTrackingTask?.cancel()
        progressTrackingTask = nil

        let detail = try? await playlistClient.getPlaylistDetail(id: playlistId)
        // Only manual playlists auto-advance / auto-remove (#532) — disarm if this one is dynamic
        // or couldn't be loaded.
        guard let detail, detail.type == .manual else {
            clear()
            return
        }
        // A later begin() may have superseded this one while the fetch was in flight (the user
        // opened a different playlist) — don't clobber the newer arm with this stale list.
        guard self.playlistId == playlistId, self.currentEpisodeId == currentEpisodeId else { return }
        orderedItems = detail.items.map { QueueItem(showId: $0.showId, episodeId: $0.episodeId) }
    }

    // Non-playlist playback (a show episode, a deep link, a CarPlay browse pick) forgets any armed
    // queue so its finish handler doesn't advance into a playlist the user has moved on from.
    func clear() {
        playlistId = nil
        currentEpisodeId = nil
        orderedItems = []
        progressTrackingTask?.cancel()
        progressTrackingTask = nil
    }

    // Called from an AudioPlayer.onDidFinishPlaying handler *after* the finished episode's
    // completion has been persisted. Removes it from the manual playlist and starts the next
    // item, or clears the queue when the playlist is exhausted.
    func handleNaturalFinish(finishedEpisodeId: String) async {
        guard let playlistId, finishedEpisodeId == currentEpisodeId else { return }

        // Best-effort — a failed removal shouldn't block advancing playback. The next sync (or
        // simply opening the playlist) still shows the episode; the user can delete it by hand.
        try? await playlistClient.removeItem(playlistId: playlistId, episodeId: finishedEpisodeId)

        guard let next = Self.nextItem(after: finishedEpisodeId, in: orderedItems) else {
            clear()
            return
        }
        currentEpisodeId = next.episodeId
        await playItem(next, playlistId: playlistId)
    }

    // Guards quickPlay() against a double-tap on a row's play button: playItem()'s episode/show/
    // settings fetches each suspend, so two overlapping calls for the same not-yet-playing episode
    // would otherwise both reach AudioPlayer.shared.play(), the second audibly restarting the
    // AVPlayerItem the first call just built.
    private var quickPlayEpisodeIdInFlight: String?

    // A list row's play button — ShowDetailView / PlaylistDetailView (#616). Starts playback
    // directly, the same way EpisodeDetailView's Play button would, without navigating there:
    // the user stays on the list, and playback continues in the mini player. Arms this as a
    // manual-playlist queue session exactly like EpisodeDetailView.startPlayback would, so
    // auto-advance (#532) still works when the row came from a manual playlist.
    func quickPlay(episodeId: String, showId: String, playlistId: String?) async {
        // Already loaded (just paused) — resume with no network round trip at all, rather than
        // re-fetching the episode/show/settings only to discover the same thing via playItem's
        // resolved audioUrl. Checked against nowPlayingContext (not currentURL) since that's
        // keyed by episodeId directly, with no download-record lookup needed to compare it.
        if AudioPlayer.shared.nowPlayingContext?.episodeId == episodeId {
            if !AudioPlayer.shared.isPlaying, let audioUrl = AudioPlayer.shared.currentURL {
                AudioPlayer.shared.resume()
                startProgressTracking(audioUrl: audioUrl, episodeId: episodeId, showId: showId)
            }
            return
        }

        guard quickPlayEpisodeIdInFlight != episodeId else { return }
        quickPlayEpisodeIdInFlight = episodeId
        defer { quickPlayEpisodeIdInFlight = nil }

        if let playlistId {
            await begin(playlistId: playlistId, currentEpisodeId: episodeId)
        } else {
            clear()
        }
        await playItem(QueueItem(showId: showId, episodeId: episodeId), playlistId: playlistId)
    }

    // Starts an episode from outside the detail screen — an auto-advance, or a direct quickPlay()
    // call from a list row's play button (#616). Deliberately mirrors CarPlaySceneDelegate.play()
    // rather than reaching into EpisodeDetailView — both are "start an arbitrary episode from
    // outside the detail screen" paths, and the app already keeps that resolution logic
    // duplicated per surface (resolvedPlaybackURL, the show-override-else-global settings fetch,
    // the periodic progress save).
    private func playItem(_ item: QueueItem, playlistId: String?) async {
        guard let episode = try? await catalogClient.getEpisode(showId: item.showId, episodeId: item.episodeId) else {
            clear()
            return
        }
        // Best-effort: only feeds the Now Playing artist/artwork.
        let show = try? await catalogClient.getShow(id: item.showId)

        async let userSettings = try? settingsClient.getSettings()
        async let showSettings = try? settingsClient.getShowSettings(showId: item.showId)
        let (user, showResolved) = await (userSettings, showSettings)
        let autoSkipIntroSeconds = TimeInterval(showResolved?.autoSkipIntroSeconds ?? user?.autoSkipIntroSeconds ?? 0)
        let autoSkipOutroSeconds = TimeInterval(showResolved?.autoSkipOutroSeconds ?? user?.autoSkipOutroSeconds ?? 0)
        let playbackSpeed = showResolved?.playbackSpeed ?? user?.playbackSpeed ?? 1.0
        let smartSpeed = showResolved?.smartSpeed ?? user?.smartSpeed ?? false

        var startPosition: TimeInterval = 0
        var downloadRecord: DownloadedEpisodeRecord?
        if let modelContainer = Self.modelContainer {
            let context = ModelContext(modelContainer)
            let episodeId = item.episodeId
            let stateDescriptor = FetchDescriptor<EpisodeStateRecord>(predicate: #Predicate { $0.id == episodeId })
            if let state = try? context.fetch(stateDescriptor).first, !state.completed {
                startPosition = TimeInterval(state.positionSeconds)
            }
            let downloadDescriptor = FetchDescriptor<DownloadedEpisodeRecord>(predicate: #Predicate { $0.id == episodeId })
            downloadRecord = try? context.fetch(downloadDescriptor).first
        }

        // Prefers a completed local download over the remote URL, same as EpisodeDetailView and
        // CarPlay.
        guard let audioUrl = EpisodeDetailView.resolvedPlaybackURL(
            audioUrlString: episode.audioUrl, downloadRecord: downloadRecord,
            downloadsDirectory: DownloadManager.downloadsDirectory())
        else {
            clear()
            return
        }

        let episodeId = item.episodeId
        let showId = item.showId
        let duration = episode.duration

        AudioPlayer.shared.onDidFinishPlaying = { [weak self] finishedURL in
            guard finishedURL == audioUrl else { return }
            Task {
                await Self.persist(episodeId: episodeId, showId: showId, positionSeconds: Int(duration ?? 0), completed: true)
                await self?.handleNaturalFinish(finishedEpisodeId: episodeId)
            }
        }

        AudioPlayer.shared.play(
            url: audioUrl, startPosition: startPosition,
            autoSkipIntroSeconds: autoSkipIntroSeconds, autoSkipOutroSeconds: autoSkipOutroSeconds,
            playbackSpeed: playbackSpeed, smartSpeed: smartSpeed,
            context: NowPlayingContext(showId: showId, episodeId: episodeId, playlistId: playlistId),
            metadata: NowPlayingMetadata(
                title: episode.title, showTitle: show?.title,
                artworkURL: show?.artworkUrl.flatMap(URL.init(string:))))

        startProgressTracking(audioUrl: audioUrl, episodeId: episodeId, showId: showId)
    }

    // Mirrors EpisodeDetailView.startProgressTracking() / CarPlay's own loop so an auto-advanced
    // episode still saves its position periodically, not only on finish.
    private func startProgressTracking(audioUrl: URL, episodeId: String, showId: String) {
        progressTrackingTask?.cancel()
        progressTrackingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled, AudioPlayer.shared.currentURL == audioUrl else { return }
                guard AudioPlayer.shared.isPlaying else { continue }
                await Self.persist(
                    episodeId: episodeId, showId: showId,
                    positionSeconds: Int(AudioPlayer.shared.currentTime), completed: false)
            }
        }
    }

    private static func persist(
        episodeId: String, showId: String, positionSeconds: Int, completed: Bool
    ) async {
        guard let syncEngine = episodeSyncEngine else { return }
        do {
            try await syncEngine.write { context in
                let descriptor = FetchDescriptor<EpisodeStateRecord>(predicate: #Predicate { $0.id == episodeId })
                if let existing = try context.fetch(descriptor).first {
                    // A periodic (completed: false) tick must never downgrade a record already
                    // marked completed — a tick can still be in flight right after a finish.
                    if !completed && existing.completed { return }
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
            // Mirrors EpisodeDetailView.persist() / CarPlay's own assertionFailure — a silent
            // try? here would hide a lost playback position / completion write.
            assertionFailure("Failed to persist episode state from PlaybackQueue: \(episodeId): \(error)")
        }
    }
}
