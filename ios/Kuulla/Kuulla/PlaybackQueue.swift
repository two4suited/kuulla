import Foundation
import Observation
import SwiftData

// Which list a playback session was started from (#629) — the thing "play next" advances
// through. A playlist (manual, dynamic or Up Next) carries its type so handleNaturalFinish knows
// whether to drop the finished episode from it (#532: manual only); a show's episode list and the
// Home / New Episodes list aren't editable in place, so nothing is removed there.
enum PlaybackListSource: Hashable {
    case playlist(id: String, type: PlaylistType)
    case show(id: String)
    case newEpisodes

    var playlistId: String? {
        if case .playlist(let id, _) = self { return id }
        return nil
    }
}

// An ordered snapshot of a list, as the screen showed it when playback began — the exact rows the
// user was looking at (a show list in its current sort/filter, a playlist in its current order).
// Carried on CatalogRoute.episode so EpisodeDetailView can arm PlaybackQueue with it, and passed
// straight to quickPlay() by a row's play button. Hashable because it rides in a NavigationLink
// value.
struct PlaybackList: Hashable {
    let source: PlaybackListSource
    let items: [PlaybackQueue.QueueItem]
}

// Auto-advance when an episode finishes (#532, generalised by #629).
//
// A single shared instance, mirroring AudioPlayer.shared: a playback session — and therefore the
// notion of "what just finished" and "what plays next" — outlives the EpisodeDetailView that
// started it, and CarPlay drives the very same AudioPlayer. Whoever starts playback of an episode
// reached from a list arms the queue with one of the begin() overloads; the
// AudioPlayer.onDidFinishPlaying handlers call handleNaturalFinish() once the finished episode's
// completion is persisted, which resolves the user's PlayNextBehavior (playlist override → show
// override → global), removes the episode from a manual playlist (#532), and starts whatever
// that behaviour picks — or stops.
//
// Every list kind is armed the same way — a snapshot of ordered items taken when the session
// began — so "what's next" needs no re-fetch and tolerates the server list shifting underneath
// (a dynamic playlist prunes the finished episode on its next recompute, for instance, which
// is exactly why the snapshot has to predate the finish).
@MainActor
@Observable
final class PlaybackQueue {
    static let shared = PlaybackQueue()

    // Set once by KuullaApp.init(), mirroring CarPlaySceneDelegate's statics — PlaybackQueue is a
    // plain shared object instantiated outside SwiftUI, with no @Environment to read the app's
    // container / sync engine from.
    static var modelContainer: ModelContainer?
    static var episodeSyncEngine: SyncEngine<EpisodeSyncAdapter>?

    // The list the current session belongs to, plus the ordered snapshot of its items taken when
    // the session began. nil / [] whenever playback didn't start from a list (a deep link, a
    // CarPlay Now Playing pick, a stale screen).
    private(set) var source: PlaybackListSource?
    private var orderedItems: [QueueItem] = []
    // Every episode finished during this session (including the one that just triggered the
    // current handleNaturalFinish call) — .topOfList needs the whole history, not just the latest
    // finish: orderedItems is a static snapshot that's never re-fetched mid-session, so without
    // this a multi-hop .topOfList chain would ping-pong forever between the snapshot's first two
    // items (each hop only knowing to skip the single episode that *just* finished) instead of
    // working through the rest of the list.
    private(set) var consumedEpisodeIds: Set<String> = []
    var playlistId: String? { source?.playlistId }
    // The episode currently playing as a queue item — guards a stale begin() (from a playlist
    // screen the user opened then backed out of without pressing Play) against advancing when
    // some unrelated episode later finishes.
    private(set) var currentEpisodeId: String?

    // The remaining items after currentEpisodeId in the armed snapshot, minus any already
    // finished this session — CarPlay's Up Next screen (#640) reads this directly rather than
    // re-deriving nextItem(after:in:behavior:) itself, since Up Next shows the plain remainder of
    // the list regardless of which PlayNextBehavior a natural finish would actually resolve to.
    var upNextItems: [QueueItem] {
        guard let currentEpisodeId,
              let index = orderedItems.firstIndex(where: { $0.episodeId == currentEpisodeId })
        else { return [] }
        return orderedItems[(index + 1)...].filter { !consumedEpisodeIds.contains($0.episodeId) }
    }

    // The full ordered snapshot, unfiltered — the Now Playing screen's inline queue (#647) renders
    // this directly (unlike upNextItems, which drops everything up to and including the current
    // episode) so already-played rows stay visible instead of disappearing from the list.
    var sessionItems: [QueueItem] { orderedItems }

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

    struct QueueItem: Hashable {
        let showId: String
        let episodeId: String
    }

    // The pure "what plays next" decision, pulled out for unit testing (mirrors
    // AudioPlayer.shouldTriggerOutroSkip / EpisodeDetailView.resolvedPlaybackURL) and kept in
    // step with PlayNext.NextItem on the web — the same list can be finished on either client.
    // .nextInList: the item after `finishedEpisodeId`, or nil at the end of the list — or if the
    // finished episode isn't in the snapshot at all (a reorder/removal race), which is likewise
    // "stop" rather than a guess. .topOfList: the first item that isn't one already finished this
    // session (the list may or may not have dropped them yet), so an exhausted list also stops —
    // `consumed` must include every episode finished so far, not just the latest one, or a
    // multi-hop chain re-settles on the snapshot's first couple of items forever instead of
    // working through the rest (finishedEpisodeId is included automatically, so a caller on its
    // first hop can pass the default empty set). Played state is otherwise not consulted here —
    // the snapshot already reflects the list's own filters (a show list under "Unfinished", a
    // dynamic playlist's pruned rules) as of when playback began.
    nonisolated static func nextItem(
        after finishedEpisodeId: String, in items: [QueueItem], behavior: PlayNextBehavior,
        consumed: Set<String> = []
    ) -> QueueItem? {
        switch behavior {
        case .stop:
            return nil
        case .topOfList:
            let consumed = consumed.union([finishedEpisodeId])
            return items.first { !consumed.contains($0.episodeId) }
        case .nextInList:
            guard let index = items.firstIndex(where: { $0.episodeId == finishedEpisodeId }),
                  index + 1 < items.count
            else { return nil }
            return items[index + 1]
        }
    }

    // Resolution order for the setting (#629): playlist override → show override → global. When
    // playback was started from a playlist, the playlist wins over the finished episode's show
    // because the user is explicitly listening to that list.
    nonisolated static func resolve(
        playlistOverride: PlayNextBehavior?, showOverride: PlayNextBehavior?, global: PlayNextBehavior
    ) -> PlayNextBehavior {
        playlistOverride ?? showOverride ?? global
    }

    // Armed by a list screen that already has its ordered rows on hand — ShowDetailView (in its
    // current sort/filter), FeedView (New Episodes), CarPlay's show browse — or by
    // EpisodeDetailView when the route carried that screen's snapshot.
    func begin(list: PlaybackList, currentEpisodeId: String) {
        rearm(source: list.source, currentEpisodeId: currentEpisodeId)
        orderedItems = list.items
    }

    // Armed by EpisodeDetailView when it starts playback of an episode reached via the
    // `.playlistEpisode` route (PlaylistDetailView, the now-playing bar), which carries only the
    // playlist id. Fetches the ordered item list once so finish handling knows the running order
    // — for manual and dynamic playlists alike (#629 removed #532's dynamic-playlist carve-out).
    func begin(playlistId: String, currentEpisodeId: String) async {
        // Armed immediately with a provisional source so a finish that races the fetch still
        // knows this was playlist playback; the type is corrected once the detail lands.
        rearm(source: .playlist(id: playlistId, type: .manual), currentEpisodeId: currentEpisodeId)

        guard let detail = try? await playlistClient.getPlaylistDetail(id: playlistId) else {
            // Deleted (404) or unreachable — nothing to advance through.
            if source?.playlistId == playlistId, self.currentEpisodeId == currentEpisodeId { clear() }
            return
        }
        // A later begin() may have superseded this one while the fetch was in flight (the user
        // opened a different list) — don't clobber the newer arm with this stale list.
        guard source?.playlistId == playlistId, self.currentEpisodeId == currentEpisodeId else { return }
        source = .playlist(id: playlistId, type: detail.type)
        orderedItems = detail.items.map { QueueItem(showId: $0.showId, episodeId: $0.episodeId) }
    }

    private func rearm(source: PlaybackListSource, currentEpisodeId: String) {
        self.source = source
        self.currentEpisodeId = currentEpisodeId
        self.orderedItems = []
        self.consumedEpisodeIds = []
        // A fresh session is taking over playback (EpisodeDetailView's Play, or a re-arm on a
        // different item) — the queue's own periodic-save loop for the previously auto-advanced
        // episode is now stale.
        progressTrackingTask?.cancel()
        progressTrackingTask = nil
    }

    // Playback that didn't start from a list (a deep link, a CarPlay Now Playing pick) forgets any
    // armed queue so its finish handler doesn't advance into a list the user has moved on from.
    func clear() {
        source = nil
        currentEpisodeId = nil
        orderedItems = []
        consumedEpisodeIds = []
        progressTrackingTask?.cancel()
        progressTrackingTask = nil
    }

    // Called from an AudioPlayer.onDidFinishPlaying handler *after* the finished episode's
    // completion has been persisted. Removes it from a manual playlist (#532), then starts
    // whatever the resolved PlayNextBehavior picks, or clears the queue when there's nothing.
    // The sleep timer's "stop at end of episode" never gets here — AudioPlayer consumes the
    // finish before the handler runs (fireOnDidFinishPlayingUnlessSleepTimerStopsHere).
    func handleNaturalFinish(finishedEpisodeId: String) async {
        guard let source, finishedEpisodeId == currentEpisodeId else { return }
        let finishedShowId = orderedItems.first { $0.episodeId == finishedEpisodeId }?.showId

        // Best-effort — a failed removal shouldn't block advancing playback. The next sync (or
        // simply opening the playlist) still shows the episode; the user can delete it by hand.
        // Dynamic playlists drop played episodes on their own server-side recompute, and show /
        // New Episodes lists aren't editable, so only a manual playlist is touched.
        if case .playlist(let playlistId, .manual) = source {
            try? await playlistClient.removeItem(playlistId: playlistId, episodeId: finishedEpisodeId)
        }

        consumedEpisodeIds.insert(finishedEpisodeId)
        let behavior = await resolvePlayNextBehavior(source: source, showId: finishedShowId)
        guard let next = Self.nextItem(
            after: finishedEpisodeId, in: orderedItems, behavior: behavior, consumed: consumedEpisodeIds)
        else {
            clear()
            return
        }
        currentEpisodeId = next.episodeId
        await playItem(next, playlistId: source.playlistId)
    }

    // Looked up at finish time rather than at begin() so an override the user edits mid-episode
    // applies to that very finish. Each layer is best-effort and falls through to the next when
    // it can't be fetched; the global value falls back to the locally-synced UserSettingsRecord
    // (a downloaded episode can finish offline) and finally to the app default.
    private func resolvePlayNextBehavior(source: PlaybackListSource, showId: String?) async -> PlayNextBehavior {
        // Independent fetches — run concurrently (mirrors playItem's own async let below) rather
        // than serially, since this runs on every episode finish and each round trip otherwise
        // adds to the gap before the next episode's audio starts.
        async let playlistDetail: PlaylistDetail? = {
            guard case .playlist(let playlistId, _) = source else { return nil }
            return try? await playlistClient.getPlaylistDetail(id: playlistId)
        }()
        async let showSettings: ShowSettings? = {
            guard let showId else { return nil }
            return try? await settingsClient.getShowSettings(showId: showId)
        }()
        async let userSettings = try? settingsClient.getSettings()

        let (playlist, show, user) = await (playlistDetail, showSettings, userSettings)
        let global = user?.playNextBehavior ?? localGlobalPlayNextBehavior() ?? .nextInList
        return Self.resolve(playlistOverride: playlist?.playNextBehavior, showOverride: show?.playNextBehavior, global: global)
    }

    private func localGlobalPlayNextBehavior() -> PlayNextBehavior? {
        guard let modelContainer = Self.modelContainer else { return nil }
        let context = ModelContext(modelContainer)
        let id = UserSettingsRecord.localId
        let descriptor = FetchDescriptor<UserSettingsRecord>(predicate: #Predicate { $0.id == id })
        return try? context.fetch(descriptor).first?.playNextBehavior
    }

    // Guards quickPlay() against a double-tap on a row's play button: playItem()'s episode/show/
    // settings fetches each suspend, so two overlapping calls for the same not-yet-playing episode
    // would otherwise both reach AudioPlayer.shared.play(), the second audibly restarting the
    // AVPlayerItem the first call just built.
    private var quickPlayEpisodeIdInFlight: String?

    // A playlist row's play button — PlaylistDetailView (#616). Starts playback directly, the same
    // way EpisodeDetailView's Play button would, without navigating there: the user stays on the
    // list, and playback continues in the mini player. Arms this as a playlist queue session
    // exactly like EpisodeDetailView.startPlayback would, so auto-advance still works.
    func quickPlay(episodeId: String, showId: String, playlistId: String?) async {
        await quickPlay(episodeId: episodeId, showId: showId) {
            if let playlistId {
                await begin(playlistId: playlistId, currentEpisodeId: episodeId)
            } else {
                clear()
            }
        }
    }

    // Same, for a row in a list the screen already has the ordered snapshot of (ShowDetailView).
    func quickPlay(episodeId: String, showId: String, list: PlaybackList) async {
        await quickPlay(episodeId: episodeId, showId: showId) {
            begin(list: list, currentEpisodeId: episodeId)
        }
    }

    // Jumps directly to an item from upNextItems (#640) — CarPlay's Up Next screen. Only advances
    // currentEpisodeId within the already-armed snapshot rather than re-arming from scratch (the
    // way quickPlay's arm() closures do for a fresh list), so a later natural finish continues
    // from this item's own position in orderedItems, and handleNaturalFinish's manual-playlist
    // removal / PlayNextBehavior resolution still see the same source they would have otherwise.
    func playUpNextItem(_ item: QueueItem) async {
        currentEpisodeId = item.episodeId
        await playItem(item, playlistId: source?.playlistId)
    }

    // The item that would play automatically when the current episode finishes — resolved exactly
    // the way handleNaturalFinish resolves it (same override lookup, same consumed set), but
    // without any of its side effects. The Now Playing screen's inline queue (#647) uses this to
    // highlight which row is "plays next" rather than assuming positional order, since a
    // .topOfList override can point somewhere other than the very next item in the snapshot.
    func resolvedNextItem() async -> QueueItem? {
        guard let source, let currentEpisodeId else { return nil }
        let showId = orderedItems.first { $0.episodeId == currentEpisodeId }?.showId
        let behavior = await resolvePlayNextBehavior(source: source, showId: showId)
        return Self.nextItem(after: currentEpisodeId, in: orderedItems, behavior: behavior, consumed: consumedEpisodeIds)
    }

    private func quickPlay(episodeId: String, showId: String, arm: () async -> Void) async {
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

        await arm()
        await playItem(QueueItem(showId: showId, episodeId: episodeId), playlistId: source?.playlistId)
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
