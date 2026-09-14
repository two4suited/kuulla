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

    // The result of resolving and preparing the next queue item's audio ahead of time (#683
    // gapless playback), started when AudioPlayer.onApproachingEnd fires and consumed (or
    // discarded) by handleNaturalFinish. Kept here — rather than re-derived from
    // AudioPlayer.shared's own preload state — because it carries the fields (duration,
    // showId/episodeId, playlistId) handleNaturalFinish needs to finish wiring the session without
    // re-running playItem()'s episode/show fetches, which is the entire point of preloading.
    private struct PreloadedNext {
        let item: QueueItem
        let audioUrl: URL
        let duration: TimeInterval?
    }
    private var preloadedNext: PreloadedNext?

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

    // The pure "should the in-flight preload be used" decision (#683), pulled out for unit testing
    // exactly like nextItem()/resolve() above. A preload started ahead of time for
    // `preloadedEpisodeId` is only still correct if it matches `next` — the *authoritative*
    // decision handleNaturalFinish just made by calling nextItem()/resolve() itself with
    // up-to-the-moment behavior/playlist state — since the preload's own guess (made up to
    // approachingEndLeadSeconds earlier) could have gone stale in the meantime (a playlist edit,
    // a PlayNextBehavior change, or the user having jumped to a different episode already).
    // `preloadIsReady` is AudioPlayer's own mechanical "did the AVPlayerItem actually finish
    // buffering" fact — kept as a separate parameter (rather than folded into a single bool by the
    // caller) so this function's two independent failure reasons (wrong episode vs. not buffered
    // yet) both stay visible to whoever's testing it.
    nonisolated static func shouldUsePreload(preloadedEpisodeId: String?, next: QueueItem, preloadIsReady: Bool) -> Bool {
        preloadIsReady && preloadedEpisodeId == next.episodeId
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
        // Without this, the episode this call is armed for never gets its own approaching-end
        // preload wired — only episodes reached via a LATER playItem()/startPlayingPreloadedItem
        // call would. Since every playback session (EpisodeDetailView's Play, CarPlay) starts here
        // before AudioPlayer.play() is called separately, that would mean the very first
        // transition of every session always took the slow path — arming it here instead closes
        // that gap (#683 follow-up).
        armApproachingEndPreload(sessionEpisodeId: currentEpisodeId)
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
        // Same reasoning as the other begin() overload — arms this session's own approaching-end
        // preload rather than leaving it only reachable via a later playItem() call.
        armApproachingEndPreload(sessionEpisodeId: currentEpisodeId)
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
        // Any preload in flight was resolved against the session being replaced — it no longer
        // corresponds to anything this re-armed session will finish into. AudioPlayer's own play()
        // would discard its side of this anyway (see AudioPlayer.play()'s own comment), but that
        // hasn't necessarily run yet at this point in begin()/quickPlay(), so drop it explicitly
        // here too rather than leaving a stale reference sitting in `preloadedNext` until it does.
        preloadedNext = nil
        AudioPlayer.shared.discardPendingPreload()
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
        preloadedNext = nil
        AudioPlayer.shared.discardPendingPreload()
        // Defense-in-depth alongside startPreloadingNext's own currentEpisodeId guard: without this,
        // a stale closure captured for whatever session was just cleared stays armed on AudioPlayer
        // until some later begin()/playItem() reassigns it.
        AudioPlayer.shared.onApproachingEnd = nil
    }

    // Called from an AudioPlayer.onDidFinishPlaying handler *after* the finished episode's
    // completion has been persisted. Removes it from every manual playlist (#532, #569 — not just
    // the one it was played from, since the same episode can be added to more than one), then
    // starts whatever the resolved PlayNextBehavior picks, or clears the queue when there's
    // nothing. The sleep timer's "stop at end of episode" never gets here — AudioPlayer consumes
    // the finish before the handler runs (fireOnDidFinishPlayingUnlessSleepTimerStopsHere).
    func handleNaturalFinish(finishedEpisodeId: String) async {
        guard let source, finishedEpisodeId == currentEpisodeId else { return }
        let finishedShowId = orderedItems.first { $0.episodeId == finishedEpisodeId }?.showId

        // Best-effort — a failed removal shouldn't block advancing playback. The next sync (or
        // simply opening the playlist) still shows the episode; the user can delete it by hand.
        // Dynamic playlists drop played episodes on their own server-side recompute, and show /
        // New Episodes lists aren't editable, so PlaylistCleanup already skips those and only
        // touches manual playlists.
        await PlaylistCleanup.removeFromManualPlaylists(
            episodeId: finishedEpisodeId, completed: true, playlistClient: playlistClient)

        consumedEpisodeIds.insert(finishedEpisodeId)
        let behavior = await resolvePlayNextBehavior(source: source, showId: finishedShowId)
        guard let next = Self.nextItem(
            after: finishedEpisodeId, in: orderedItems, behavior: behavior, consumed: consumedEpisodeIds)
        else {
            clear()
            return
        }

        // A preload started ~approachingEndLeadSeconds ago may already have this episode's audio
        // buffered and ready — if it's still the authoritative pick (see shouldUsePreload's own
        // comment on why that can't just be assumed) and AudioPlayer confirms it's actually ready,
        // swap to it directly instead of running playItem()'s full episode/show/settings
        // resolution chain live, which is exactly the network/DB-latency gap #683 exists to close.
        if let preloadedNext, Self.shouldUsePreload(
            preloadedEpisodeId: preloadedNext.item.episodeId, next: next,
            preloadIsReady: AudioPlayer.shared.hasPendingPreload(for: preloadedNext.audioUrl)
        ) {
            self.preloadedNext = nil
            currentEpisodeId = next.episodeId
            startPlayingPreloadedItem(preloadedNext, playlistId: source.playlistId)
            return
        }

        preloadedNext = nil
        AudioPlayer.shared.discardPendingPreload()
        currentEpisodeId = next.episodeId
        await playItem(next, playlistId: source.playlistId)
    }

    // The fast path counterpart to playItem() below — wires up onDidFinishPlaying and progress
    // tracking exactly the same way, but swaps AudioPlayer straight to the already-prepared
    // preload instead of awaiting a fresh episode/show/settings resolution and building a new
    // AVPlayerItem. Synchronous (unlike playItem()) since everything it needs was already resolved
    // when the preload was started — that's the entire point.
    private func startPlayingPreloadedItem(_ preloaded: PreloadedNext, playlistId: String?) {
        let episodeId = preloaded.item.episodeId
        let showId = preloaded.item.showId
        let duration = preloaded.duration
        let audioUrl = preloaded.audioUrl

        AudioPlayer.shared.onDidFinishPlaying = { [weak self] finishedURL in
            guard finishedURL == audioUrl else { return }
            Task {
                await Self.persist(episodeId: episodeId, showId: showId, positionSeconds: Int(duration ?? 0), completed: true)
                await self?.handleNaturalFinish(finishedEpisodeId: episodeId)
            }
        }

        // Falls back to the full slow path if AudioPlayer's own state changed out from under us
        // between the hasPendingPreload() check above and this call (e.g. it somehow lost
        // readiness) — defensive, since shouldUsePreload already checked readiness, but
        // swapToPendingPreload's own guard is the one source of truth for whether the swap
        // actually happened.
        guard AudioPlayer.shared.swapToPendingPreload() else {
            Task { await playItem(preloaded.item, playlistId: playlistId) }
            return
        }

        armApproachingEndPreload(sessionEpisodeId: episodeId)
        startProgressTracking(audioUrl: audioUrl, episodeId: episodeId, showId: showId)
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

    // Everything resolvePlayableEpisode() below needs to hand back to a caller that's actually
    // going to use the result — either to start playback now (playItem) or to preload it ahead of
    // time (startPreloadingNext, #683).
    private struct ResolvedPlayableEpisode {
        let audioUrl: URL
        let episode: Episode
        let show: Show?
        let startPosition: TimeInterval
        let autoSkipIntroSeconds: TimeInterval
        let autoSkipOutroSeconds: TimeInterval
        let playbackSpeed: Float
        let smartSpeed: Bool
        let voiceBoost: Bool
        let trimSilence: Bool
        let volumeOffsetDb: Float
    }

    // The episode/show/settings/download-record resolution chain shared by playItem() and
    // startPreloadingNext() (#683) — pulled out so gapless preloading runs exactly the same
    // resolution playItem() always has, rather than a hand-duplicated (and possibly
    // drifted-out-of-sync) copy of it. Returns nil when the episode can't be resolved at all
    // (deleted, unreachable) or has no playable URL — callers decide what "give up" means for
    // their own context: playItem() clears the whole queue, while a failed preload just quietly
    // skips preloading and lets the slow path run again at actual finish time.
    private func resolvePlayableEpisode(_ item: QueueItem) async -> ResolvedPlayableEpisode? {
        guard let episode = try? await catalogClient.getEpisode(showId: item.showId, episodeId: item.episodeId) else {
            return nil
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
        let voiceBoost = showResolved?.voiceBoost ?? user?.voiceBoost ?? false
        let trimSilence = showResolved?.trimSilence ?? user?.trimSilence ?? false
        let volumeOffsetDb = showResolved?.volumeOffsetDb ?? user?.volumeOffsetDb ?? 0

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
        else { return nil }

        return ResolvedPlayableEpisode(
            audioUrl: audioUrl, episode: episode, show: show, startPosition: startPosition,
            autoSkipIntroSeconds: autoSkipIntroSeconds, autoSkipOutroSeconds: autoSkipOutroSeconds,
            playbackSpeed: playbackSpeed, smartSpeed: smartSpeed, voiceBoost: voiceBoost, trimSilence: trimSilence,
            volumeOffsetDb: volumeOffsetDb)
    }

    // Starts an episode from outside the detail screen — an auto-advance, or a direct quickPlay()
    // call from a list row's play button (#616). Deliberately mirrors CarPlaySceneDelegate.play()
    // rather than reaching into EpisodeDetailView — both are "start an arbitrary episode from
    // outside the detail screen" paths, and the app already keeps that resolution logic
    // duplicated per surface (resolvedPlaybackURL, the show-override-else-global settings fetch,
    // the periodic progress save).
    private func playItem(_ item: QueueItem, playlistId: String?) async {
        guard let resolved = await resolvePlayableEpisode(item) else {
            clear()
            return
        }

        let episodeId = item.episodeId
        let showId = item.showId
        let duration = resolved.episode.duration
        let audioUrl = resolved.audioUrl

        AudioPlayer.shared.onDidFinishPlaying = { [weak self] finishedURL in
            guard finishedURL == audioUrl else { return }
            Task {
                await Self.persist(episodeId: episodeId, showId: showId, positionSeconds: Int(duration ?? 0), completed: true)
                await self?.handleNaturalFinish(finishedEpisodeId: episodeId)
            }
        }

        AudioPlayer.shared.play(
            url: audioUrl, startPosition: resolved.startPosition,
            autoSkipIntroSeconds: resolved.autoSkipIntroSeconds, autoSkipOutroSeconds: resolved.autoSkipOutroSeconds,
            playbackSpeed: resolved.playbackSpeed, smartSpeed: resolved.smartSpeed,
            voiceBoost: resolved.voiceBoost, trimSilence: resolved.trimSilence,
            volumeOffsetDb: resolved.volumeOffsetDb,
            context: NowPlayingContext(showId: showId, episodeId: episodeId, playlistId: playlistId),
            metadata: NowPlayingMetadata(
                title: resolved.episode.title, showTitle: resolved.show?.title,
                artworkURL: resolved.show?.artworkUrl.flatMap(URL.init(string:))))

        armApproachingEndPreload(sessionEpisodeId: episodeId)
        startProgressTracking(audioUrl: audioUrl, episodeId: episodeId, showId: showId)
    }

    // MARK: - Gapless preload (#683)

    // Arms AudioPlayer.onApproachingEnd for the session that just started playing
    // `sessionEpisodeId` — single-slot, reassigned by every playItem() call (and by the fast swap
    // path in startPlayingPreloadedItem below) exactly like onDidFinishPlaying's own wiring, so
    // whichever episode is actually playing owns the callback.
    private func armApproachingEndPreload(sessionEpisodeId: String) {
        AudioPlayer.shared.onApproachingEnd = { [weak self] in
            Task { await self?.startPreloadingNext(sessionEpisodeId: sessionEpisodeId) }
        }
    }

    // Resolves and preloads whatever nextItem()/resolve() currently pick as "plays after
    // sessionEpisodeId" — called once per session, ~AudioPlayer.approachingEndLeadSeconds before
    // it naturally ends. Deliberately re-runs the same nextItem()/resolve() lookup
    // handleNaturalFinish will run again at the actual finish (rather than caching this call's
    // result as final) since a playlist edit or PlayNextBehavior change in the intervening seconds
    // must not be preloaded past — shouldUsePreload() is what actually reconciles the two lookups
    // at finish time.
    private func startPreloadingNext(sessionEpisodeId: String) async {
        guard let source, currentEpisodeId == sessionEpisodeId else { return }
        let showId = orderedItems.first { $0.episodeId == sessionEpisodeId }?.showId
        let behavior = await resolvePlayNextBehavior(source: source, showId: showId)
        // The user may have skipped to a different episode entirely while this was in flight —
        // mirrors playItem's own staleness guards (and resolvedNextItem's precondition) against
        // acting on a resolution that's no longer for the episode actually still playing.
        guard currentEpisodeId == sessionEpisodeId,
              let next = Self.nextItem(after: sessionEpisodeId, in: orderedItems, behavior: behavior, consumed: consumedEpisodeIds)
        else { return }

        guard let resolved = await resolvePlayableEpisode(next), currentEpisodeId == sessionEpisodeId else { return }

        preloadedNext = PreloadedNext(item: next, audioUrl: resolved.audioUrl, duration: resolved.episode.duration)
        AudioPlayer.shared.preloadNext(
            url: resolved.audioUrl, startPosition: resolved.startPosition,
            autoSkipIntroSeconds: resolved.autoSkipIntroSeconds, playbackSpeed: resolved.playbackSpeed,
            autoSkipOutroSeconds: resolved.autoSkipOutroSeconds,
            smartSpeed: resolved.smartSpeed, voiceBoost: resolved.voiceBoost, trimSilence: resolved.trimSilence,
            volumeOffsetDb: resolved.volumeOffsetDb,
            context: NowPlayingContext(showId: next.showId, episodeId: next.episodeId, playlistId: playlistId),
            metadata: NowPlayingMetadata(
                title: resolved.episode.title, showTitle: resolved.show?.title,
                artworkURL: resolved.show?.artworkUrl.flatMap(URL.init(string:))))
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
