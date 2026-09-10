import AVFoundation
import MediaPlayer
import UIKit

// Metadata for the lock screen / Control Center / CarPlay Now Playing surfaces, all of which read
// from MPNowPlayingInfoCenter rather than anything AudioPlayer exposes directly. Episode.swift has
// no artwork of its own (only Show does), so artworkURL is threaded in by the caller from the show.
struct NowPlayingMetadata {
    let title: String
    let showTitle: String?
    let artworkURL: URL?
}

// Identity of the currently loaded episode plus the playlist it was started from. Read by the
// in-app now-playing bar (#542) to deep-link back to the right EpisodeDetailView — threading
// playlistId keeps playlist auto-advance (#532) armed when the episode is reopened from the bar.
// Kept separate from NowPlayingMetadata, which is purely the lock screen / CarPlay display payload.
struct NowPlayingContext: Equatable {
    let showId: String
    let episodeId: String
    let playlistId: String?
}

@Observable
final class AudioPlayer {
    // A single shared instance so playback survives navigation between episode screens
    // (each screen creating its own player would tear down playback — and drop the shared
    // AVAudioSession — the moment the view is popped, defeating background audio).
    static let shared = AudioPlayer()

    private var player: AVPlayer?
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var currentURL: URL?

    // Set when play() refuses to start a remote stream because Wi-Fi-only streaming (#271) is on
    // and the device isn't currently on Wi-Fi — cleared at the start of every play() call
    // (successful or not) so a stale message doesn't linger after the user reconnects or retries.
    // Paired with the URL it applies to (mirroring onDidFinishPlaying's per-URL guard below):
    // AudioPlayer.shared is a single global instance, so without this a message set while blocked
    // on one episode would otherwise keep showing under an unrelated episode's Play button after
    // the user merely navigates away, without that other episode's own play() ever having run.
    private(set) var streamBlockedMessage: String?
    private(set) var streamBlockedURL: URL?

    // Pessimistic default (mirrors DownloadManager's isOnWifi): only LocalSettings.wifiOnlyStreaming
    // == true even looks at this value, so defaulting to "not on Wi-Fi" costs nothing when the
    // setting is off, and avoids a stream starting over cellular in the brief window before the
    // path observer's first real callback lands when the setting is on.
    private var isOnWifi = false

    // Exposes the underlying AVPlayer's actual rate/pitch-algorithm for tests to assert against
    // directly — the bookkeeping playbackSpeed property below would still read correctly even if
    // the .rate assignment or .timeDomain wiring in play()/setPlaybackSpeed() were broken.
    var currentPlayerRate: Float? { player?.rate }
    var currentPitchAlgorithm: AVAudioTimePitchAlgorithm? { player?.currentItem?.audioTimePitchAlgorithm }

    // Fires once, on the main queue, when the current item finishes playing naturally (not on a
    // manual pause). A single slot rather than a broadcast mechanism — callers should assign this
    // only at the point they start playback for a specific URL (not merely on screen appearance),
    // so a screen that never presses play can't steal the callback from whichever episode is
    // actually playing in the background.
    var onDidFinishPlaying: ((URL) -> Void)?

    private var timeObserverToken: Any?
    private var endObserver: NSObjectProtocol?

    // The current session's SmartSpeed processor, purely so play()/removeObservers() have
    // something to reference — its actual memory lifetime is owned by the tap itself (see
    // SmartSpeedProcessor.makeAudioMix's passRetained/release), independent of this property. nil
    // whenever SmartSpeed is off, so the tap-processing cost is only ever paid when the feature is
    // actually in use.
    private var smartSpeedProcessor: SmartSpeedProcessor?

    private var autoSkipOutroSeconds: TimeInterval = 0
    // Guards against firing the outro skip more than once per playback (the periodic time
    // observer keeps ticking after the skip fires, since the item is merely paused, not
    // deallocated or seeked to its true end).
    private var hasTriggeredOutroSkip = false

    // Counts down in real wall-clock time via its own Timer, independent of AVPlayer's periodic
    // time observer — a sleep timer should keep ticking (and eventually fire) even while playback
    // is paused, not buy the user extra listening time. Not persisted or synced (#207): a
    // relaunch always starts with no sleep timer active, matching LocalSettings' device-local,
    // non-synced conventions for other session state. Survives across play() calls (switching
    // episodes doesn't cancel it) — only cancelSleepTimer() or expiry clears it.
    private(set) var sleepTimerRemainingSeconds: TimeInterval?
    // True while an "end of current episode" sleep timer is armed. Checked at both
    // onDidFinishPlaying call sites below (natural end-of-file and the outro auto-skip) so
    // reaching the end of whatever's currently playing stops playback outright instead of running
    // the caller's normal onDidFinishPlaying behavior (typically auto-advancing to the next
    // episode) — that's the whole point of this mode.
    private(set) var sleepTimerEndOfEpisodeEnabled = false
    private var sleepTimer: Timer?

    // The desired session rate. Not always what AVPlayer.rate itself reads (that's 0 while
    // paused, or before a seek/buffer completes), but the value play()/resume()/setPlaybackSpeed()
    // apply and reapply — tracked separately so pause/resume can restore it without needing to
    // remember what was last actually playing.
    private(set) var playbackSpeed: Float = 1.0

    // Non-nil exactly while a saved-position seek (from play(), or a skip/scrub issued before
    // that one landed) is outstanding for this player. isPlaying is set true optimistically
    // before the seek lands (so the UI shows "Playing" immediately), so this is the only reliable
    // way to tell "audio hasn't actually started yet" apart from "audio is paused" — both
    // otherwise look like isPlaying == true/false respectively from the outside. Cleared on the
    // governing seek's completion, on pause() (so a completion that fires after a pause can't
    // resume playback out from under the user), and reset by play() starting a new session.
    private var pendingSeekPlayer: AVPlayer?

    // Monotonically increasing; stamps each "governing" seek — the saved-position seek play()
    // issues, plus any skip/scrub that supersedes one still in flight. AVPlayer fires a
    // cancelled seek's completion too (with finished == false), so a fast skip landing during
    // play()'s resume-seek would otherwise start playback at the cancelled seek's target. Only
    // the completion whose captured generation still matches the current one — and that lands
    // with finished == true — is allowed to start playback; every earlier, superseded seek's
    // completion is ignored. See issueGoverningSeek / completeGoverningSeek.
    private var pendingSeekGeneration = 0

    // Test-only window onto the generation counter (mirrors currentPlayerRate) so a test can
    // capture "the generation as of this seek" and later drive completeGoverningSeek directly —
    // AVPlayer's seek completion can't be triggered deterministically against a fake asset.
    var currentSeekGeneration: Int { pendingSeekGeneration }

    // Retained for the object's lifetime — startObserving's closure only captures `onUpdate`, not
    // the observer itself, so an unretained NWPathMonitorAdapter would deinit right after this
    // init returns, silently stopping path updates and leaving isOnWifi stuck at its pessimistic
    // default (Wi-Fi-only streaming would then block forever, even while genuinely on Wi-Fi).
    private var pathObserver: NetworkPathObserving

    // Backs the lock screen / Control Center / CarPlay Now Playing surfaces. Nil whenever nothing
    // is loaded, so updateNowPlayingInfo() can clear MPNowPlayingInfoCenter instead of showing
    // stale metadata for a session that's already gone.
    private(set) var nowPlayingMetadata: NowPlayingMetadata?
    // Set by play() alongside nowPlayingMetadata; read by the in-app now-playing bar (#542) to
    // route back to this episode. nil until the first play() of the process.
    private(set) var nowPlayingContext: NowPlayingContext?
    private var artwork: MPMediaItemArtwork?
    // Tracks which artwork URL the in-flight (or most recently completed) fetch was for, so a
    // second play() call for the same show doesn't re-download artwork already fetched, and a
    // stale completion for a since-replaced show can't clobber the current one's artwork.
    private var artworkURLBeingFetched: URL?

    // pathObserver is a test-only seam (mirroring DownloadManager's) — production always uses the
    // real NWPathMonitor-backed default; tests inject a mock to simulate Wi-Fi/cellular
    // transitions deterministically.
    init(pathObserver: NetworkPathObserving = NWPathMonitorAdapter()) {
        self.pathObserver = pathObserver
        configureAudioSession()
        configureRemoteCommandCenter()
        self.pathObserver.startObserving { [weak self] isOnWifi in
            DispatchQueue.main.async { self?.isOnWifi = isOnWifi }
        }
    }

    deinit {
        sleepTimer?.invalidate()
    }

    func play(
        url: URL, startPosition: TimeInterval = 0,
        autoSkipIntroSeconds: TimeInterval = 0, autoSkipOutroSeconds: TimeInterval = 0,
        playbackSpeed: Float = 1.0, smartSpeed: Bool = false,
        context: NowPlayingContext? = nil, metadata: NowPlayingMetadata? = nil
    ) {
        streamBlockedMessage = nil
        streamBlockedURL = nil

        // Only gates a genuine remote stream — a downloaded local file (#177) plays fine over
        // cellular, or with no connection at all; it isn't "streaming".
        if !url.isFileURL && LocalSettings.wifiOnlyStreaming && !isOnWifi {
            streamBlockedMessage = "Streaming is limited to Wi-Fi. Connect to Wi-Fi, or turn off "
                + "\"Stream over Wi-Fi only\" in Settings, to continue."
            streamBlockedURL = url
            return
        }

        removeObservers()

        // A previous session's saved-position seek (if any) is now moot — drop it and bump the
        // generation so its still-in-flight completion, whenever it lands, can't apply a rate to
        // this new session's player.
        pendingSeekPlayer = nil
        pendingSeekGeneration += 1

        let item = AVPlayerItem(url: url)
        // .timeDomain keeps pitch unchanged as rate varies — spoken-word content should speed up
        // without the chipmunk effect a naive rate change would produce.
        item.audioTimePitchAlgorithm = .timeDomain

        if smartSpeed {
            let processor = SmartSpeedProcessor()
            // Captures item weakly so a later play() that replaces self.player (and drops this
            // item) can't have this stale session's detector adjust the new player's rate out
            // from under it — the identity check below is the real guard, this just avoids
            // retaining a dead item purely to compare against.
            processor.onSilenceStateChanged = { [weak self, weak item] isSilent in
                DispatchQueue.main.async {
                    // isPlaying/pendingSeekPlayer guards mirror setPlaybackSpeed's own: a paused
                    // session must not have this resume it by setting a nonzero rate, and a
                    // saved-position seek still in flight must not have its deferred-start-until-
                    // seeked behavior defeated by a rate change landing early.
                    guard let self, let item, self.player?.currentItem === item,
                          self.isPlaying, self.pendingSeekPlayer == nil
                    else { return }
                    self.player?.rate = isSilent
                        ? self.playbackSpeed * SmartSpeedProcessor.silenceSkipRateMultiplier
                        : self.playbackSpeed
                }
            }
            item.audioMix = processor.makeAudioMix(for: item)
            smartSpeedProcessor = processor
        } else {
            smartSpeedProcessor = nil
        }

        let newPlayer = AVPlayer(playerItem: item)
        player = newPlayer
        currentURL = url
        duration = 0
        self.autoSkipOutroSeconds = autoSkipOutroSeconds
        self.playbackSpeed = playbackSpeed
        hasTriggeredOutroSkip = false

        // Only skip the intro on a fresh start (startPosition 0) — a saved resume position
        // means playback already passed the intro once, so it shouldn't be skipped again on
        // every resume.
        let effectiveStartPosition = startPosition > 0 ? startPosition : autoSkipIntroSeconds
        currentTime = effectiveStartPosition

        // AVPlayer.seek(to:) is asynchronous — calling play() immediately after would let playback
        // start audibly at 0s and then jump once the seek lands. Deferring the rate-apply to the
        // seek's completion handler makes resume-from-position actually start at that position.
        // Setting .rate rather than calling .play() starts playback at the configured speed
        // directly, instead of starting at 1.0 and then jumping.
        if effectiveStartPosition > 0 {
            issueGoverningSeek(to: CMTime(seconds: effectiveStartPosition, preferredTimescale: 600))
        } else {
            newPlayer.rate = playbackSpeed
        }
        isPlaying = true
        nowPlayingContext = context
        applyMetadata(metadata)

        timeObserverToken = newPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            guard let self else { return }
            self.currentTime = time.seconds
            if let itemDuration = newPlayer.currentItem?.duration.seconds, itemDuration.isFinite {
                self.duration = itemDuration
            }
            self.checkAutoSkipOutro(url: url)
            self.updateNowPlayingInfo()
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // Guard against double-firing onDidFinishPlaying: if the outro skip already fired
            // for this session, the item is merely paused a few seconds before its real end —
            // if the user resumes and lets it play out, this notification would otherwise fire
            // a second finish for the same playback.
            guard !self.hasTriggeredOutroSkip else { return }
            self.isPlaying = false
            self.updateNowPlayingInfo()
            self.fireOnDidFinishPlayingUnlessSleepTimerStopsHere(url: url)
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        // Cancels a saved-position seek's pending rate-apply, if one is outstanding — otherwise
        // that completion could still land after this pause and resume playback unexpectedly.
        pendingSeekPlayer = nil
        updateNowPlayingInfo()
    }

    func resume() {
        // .rate rather than .play() so resuming doesn't silently reset speed back to 1.0.
        player?.rate = playbackSpeed
        isPlaying = true
        updateNowPlayingInfo()
    }

    func seek(to time: TimeInterval) {
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        currentTime = time
        if pendingSeekPlayer != nil {
            // play()'s saved-position seek hasn't landed yet. Issue this one as the new governing
            // seek so playback starts from *this* target once it actually lands — and so the
            // earlier seek's cancelled completion (finished == false, now-stale generation) can't
            // start playback at the superseded position.
            issueGoverningSeek(to: cmTime)
        } else {
            player?.seek(to: cmTime)
        }
        updateNowPlayingInfo()
    }

    // Issues a seek whose completion is the one allowed to start playback (apply playbackSpeed,
    // clear pendingSeekPlayer). Bumps the generation so that if another governing seek is issued
    // before this one lands, only the latest one's completion — landing with finished == true —
    // starts playback; earlier, cancelled seeks' completions are ignored.
    private func issueGoverningSeek(to cmTime: CMTime) {
        guard let seekPlayer = player else { return }
        pendingSeekPlayer = seekPlayer
        pendingSeekGeneration += 1
        let generation = pendingSeekGeneration
        // AVPlayer's seek completion handler isn't guaranteed to run on the main queue, but every
        // property completeGoverningSeek touches is otherwise only ever read/written on main —
        // dispatch explicitly rather than relying on incidental timing.
        seekPlayer.seek(to: cmTime) { [weak self] finished in
            DispatchQueue.main.async { self?.completeGoverningSeek(generation: generation, finished: finished) }
        }
    }

    // The body of a governing seek's completion handler, pulled out as an internal test seam
    // (mirroring tickSleepTimer / fireOnDidFinishPlayingUnlessSleepTimerStopsHere) — AVPlayer's
    // seek completion can't be driven deterministically against a fake asset in a unit test.
    //
    // `finished` is AVPlayer's "this seek ran to completion" flag, false when a newer seek
    // cancelled it. A cancelled seek still fires its completion, so without this check a fast
    // skip/scrub landing during play()'s initial resume-seek would start playback at the
    // cancelled seek's target. `generation` guards the same race from the other side: once a
    // later governing seek has been issued, only that later one may start playback. Reads
    // self.playbackSpeed at completion time so a setPlaybackSpeed() during the pending seek isn't
    // silently overwritten once this lands.
    func completeGoverningSeek(generation: Int, finished: Bool) {
        guard finished, generation == pendingSeekGeneration,
              let seekPlayer = pendingSeekPlayer, seekPlayer === player
        else { return }
        pendingSeekPlayer = nil
        seekPlayer.rate = playbackSpeed
    }

    // Changes the rate of the current playback session. No-ops the underlying player when
    // paused — setting AVPlayer.rate to a nonzero value always (re)starts playback, which would
    // incorrectly resume a paused episode just because the user changed the speed setting.
    // Also no-ops while a saved-position seek is still pending: isPlaying is already true
    // optimistically at that point (set by play() before the seek lands), so applying the rate
    // here would start audio playing from whatever position it happens to be at right now,
    // before the seek completes — defeating play()'s deferred-start-until-seeked behavior. The
    // seek's own completion handler applies this playbackSpeed once it fires.
    func setPlaybackSpeed(_ speed: Float) {
        playbackSpeed = speed
        if isPlaying && pendingSeekPlayer == nil {
            player?.rate = speed
        }
    }

    // Corrects a play() call that started before this episode's Now Playing metadata (show
    // title/artwork) had resolved, mirroring setPlaybackSpeed()'s same live-correction pattern —
    // callers apply this once the metadata they raced against finally arrives.
    func updateMetadata(_ metadata: NowPlayingMetadata?) {
        applyMetadata(metadata)
    }

    // MARK: - Sleep timer

    // Starts (replacing any existing countdown or "end of episode" mode) a duration-based sleep
    // timer that pauses playback once `minutes` of real time have elapsed.
    func startSleepTimer(minutes: Int) {
        sleepTimerEndOfEpisodeEnabled = false
        sleepTimerRemainingSeconds = TimeInterval(minutes * 60)
        sleepTimer?.invalidate()
        // Timer.scheduledTimer(withTimeInterval:...) schedules into the run loop's .default mode
        // only, which stops firing during UI event tracking (e.g. a user scrolling the episode
        // list) — exactly the kind of interaction someone would do while a sleep timer is
        // counting down in the background. Constructing the timer directly and adding it to
        // RunLoop.main in .common (rather than just .default) keeps it firing through tracking.
        // The callback already always lands on main (RunLoop.main), so no DispatchQueue hop is
        // needed to call tickSleepTimer() safely.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.tickSleepTimer()
        }
        RunLoop.main.add(timer, forMode: .common)
        sleepTimer = timer
    }

    // Arms "stop at the end of whatever's currently playing" instead of a duration countdown —
    // see fireOnDidFinishPlayingUnlessSleepTimerStopsHere for where this actually takes effect.
    func startSleepTimerForEndOfEpisode() {
        sleepTimer?.invalidate()
        sleepTimer = nil
        sleepTimerRemainingSeconds = nil
        sleepTimerEndOfEpisodeEnabled = true
    }

    // Adds (or, with a negative value, subtracts) minutes from an already-running duration
    // countdown, clamped so it can't go negative. A no-op when no duration countdown is active
    // (nil remaining, or "end of episode" mode) — there's nothing to adjust.
    func adjustSleepTimer(byMinutes minutes: Int) {
        guard let remaining = sleepTimerRemainingSeconds else { return }
        sleepTimerRemainingSeconds = max(0, remaining + TimeInterval(minutes * 60))
    }

    func cancelSleepTimer() {
        sleepTimer?.invalidate()
        sleepTimer = nil
        sleepTimerRemainingSeconds = nil
        sleepTimerEndOfEpisodeEnabled = false
    }

    // Internal (not private) so tests can drive the countdown deterministically instead of
    // waiting on a real Timer's 1-second ticks — mirrors shouldTriggerOutroSkip's pure-function
    // test seam below, just as a method instead of a static func since it mutates state.
    func tickSleepTimer() {
        guard let remaining = sleepTimerRemainingSeconds else { return }
        let next = remaining - 1
        if next <= 0 {
            // nil (not 0) once expired — nil is this property's sole "inactive" contract, checked
            // by tickSleepTimer's own early-return guard above, adjustSleepTimer, and UI callers
            // (e.g. EpisodeDetailView's button title) that use it to decide whether a countdown
            // is running at all. Leaving it at 0 would satisfy `if let` everywhere else, letting
            // an already-expired timer look active (and be "adjusted" back to a positive value
            // with no Timer left to actually count it down).
            sleepTimerRemainingSeconds = nil
            sleepTimer?.invalidate()
            sleepTimer = nil
            pause()
        } else {
            sleepTimerRemainingSeconds = next
        }
    }

    // Shared by play() and updateMetadata() so the artwork-cache invalidation only lives in one
    // place. A new artwork URL (including nil, e.g. a show with no artwork) clears both the
    // cached image and the in-flight/completed-fetch marker — clearing only `artwork` and
    // leaving `artworkURLBeingFetched` pointed at the old URL would make fetchArtworkIfNeeded
    // believe that URL's artwork is already fetched (or being fetched) forever, so returning to
    // that same show later would never re-fetch it despite `artwork` having been cleared.
    private func applyMetadata(_ metadata: NowPlayingMetadata?) {
        if metadata?.artworkURL != nowPlayingMetadata?.artworkURL {
            artwork = nil
            artworkURLBeingFetched = nil
        }
        nowPlayingMetadata = metadata
        updateNowPlayingInfo()
        fetchArtworkIfNeeded(for: metadata)
    }

    // Fires the same finish semantics as a natural end-of-file (isPlaying = false,
    // onDidFinishPlaying) once currentTime reaches duration - autoSkipOutroSeconds — distinct
    // from AVPlayerItemDidPlayToEndTime, but intentionally treated the same way so an
    // auto-skipped outro still counts as a completed play (consistent with existing
    // auto-played-episode conventions) rather than looking like an interrupted/abandoned one.
    private func checkAutoSkipOutro(url: URL) {
        guard !hasTriggeredOutroSkip,
              Self.shouldTriggerOutroSkip(currentTime: currentTime, duration: duration, autoSkipOutroSeconds: autoSkipOutroSeconds)
        else { return }

        hasTriggeredOutroSkip = true
        player?.pause()
        isPlaying = false
        fireOnDidFinishPlayingUnlessSleepTimerStopsHere(url: url)
    }

    // Shared by the natural end-of-file observer and the outro auto-skip above — both represent
    // "this episode just finished," which is exactly what an "end of episode" sleep timer is
    // waiting for. When armed, this consumes it and stops here instead of invoking the caller's
    // onDidFinishPlaying, which would otherwise auto-advance to the next episode.
    //
    // Internal (not private) so tests can drive it directly instead of needing a real AVPlayer to
    // reach AVPlayerItemDidPlayToEndTime or the outro-skip threshold — mirrors tickSleepTimer's
    // own test seam above.
    func fireOnDidFinishPlayingUnlessSleepTimerStopsHere(url: URL) {
        if sleepTimerEndOfEpisodeEnabled {
            sleepTimerEndOfEpisodeEnabled = false
            return
        }
        onDidFinishPlaying?(url)
    }

    // Pulled out as a pure function so the boundary condition is unit-testable without needing
    // a real, ticking AVPlayer. A non-positive threshold (autoSkipOutroSeconds >= duration) means
    // the configured outro is longer than the episode itself, so it's never eligible to fire —
    // that's treated as misconfiguration rather than "skip the whole episode instantly".
    static func shouldTriggerOutroSkip(currentTime: TimeInterval, duration: TimeInterval, autoSkipOutroSeconds: TimeInterval) -> Bool {
        guard autoSkipOutroSeconds > 0, duration > 0 else { return false }
        let threshold = duration - autoSkipOutroSeconds
        guard threshold > 0 else { return false }
        return currentTime >= threshold
    }

    private func removeObservers() {
        if let timeObserverToken {
            player?.removeTimeObserver(timeObserverToken)
            self.timeObserverToken = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio)
        try? session.setActive(true)
    }

    // Guards against registering more than once per process — MPRemoteCommandCenter.shared() is a
    // singleton, so every AudioPlayer() instance would otherwise stack another set of targets onto
    // it with no way to remove them. Harmless for production (AudioPlayer.shared is the only
    // instance that's ever created), but AudioPlayerTests constructs a fresh AudioPlayer() per
    // test — without this guard the shared command center would accumulate dozens of stale
    // handlers over a single test run.
    private static var hasConfiguredRemoteCommandCenter = false

    // Registered once per process against the process-wide MPRemoteCommandCenter — this is what
    // CarPlay's CPNowPlayingTemplate, the lock screen, and Control Center all send their
    // play/pause/skip taps through, independent of any CarPlay-specific UI code (#118).
    private func configureRemoteCommandCenter() {
        guard !Self.hasConfiguredRemoteCommandCenter else { return }
        Self.hasConfiguredRemoteCommandCenter = true

        let commandCenter = MPRemoteCommandCenter.shared()

        // MPRemoteCommandCenter isn't documented to invoke targets on the main thread, but every
        // property these touch (player, isPlaying, currentTime, ...) is otherwise only ever
        // read/written on main (mirroring the periodic time observer and pathObserver callback
        // above) — running via Self.onMain here keeps that guarantee instead of racing with it.
        // Each target just unpacks the event and calls a handle*Command method below — kept
        // separate so tests can call those directly (MPRemoteCommandEvent has no public
        // initializer, so a real command can't otherwise be simulated in a test).
        commandCenter.playCommand.addTarget { [weak self] _ in
            guard let self else { return .noActionableNowPlayingItem }
            return Self.onMain { self.handlePlayCommand() }
        }
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .noActionableNowPlayingItem }
            return Self.onMain { self.handlePauseCommand() }
        }
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .noActionableNowPlayingItem }
            return Self.onMain { self.handleTogglePlayPauseCommand() }
        }
        // 15s back / 30s forward matches the common podcast-app convention.
        commandCenter.skipBackwardCommand.preferredIntervals = [15]
        commandCenter.skipBackwardCommand.addTarget { [weak self] event in
            guard let self, let event = event as? MPSkipIntervalCommandEvent else { return .noActionableNowPlayingItem }
            return Self.onMain { self.handleSkipBackwardCommand(interval: event.interval) }
        }
        commandCenter.skipForwardCommand.preferredIntervals = [30]
        commandCenter.skipForwardCommand.addTarget { [weak self] event in
            guard let self, let event = event as? MPSkipIntervalCommandEvent else { return .noActionableNowPlayingItem }
            return Self.onMain { self.handleSkipForwardCommand(interval: event.interval) }
        }
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, let event = event as? MPChangePlaybackPositionCommandEvent else { return .noActionableNowPlayingItem }
            return Self.onMain { self.handleChangePlaybackPositionCommand(positionTime: event.positionTime) }
        }
    }

    // CarPlay's CPNowPlayingTemplate sends its play/pause/skip taps through these same
    // MPRemoteCommandCenter targets — there's no separate CarPlay playback path (#118), so
    // verifying these round-trip through play()/pause()/resume()/seek() covers CarPlay too.
    @discardableResult
    func handlePlayCommand() -> MPRemoteCommandHandlerStatus {
        guard player != nil else { return .noActionableNowPlayingItem }
        resume()
        return .success
    }

    @discardableResult
    func handlePauseCommand() -> MPRemoteCommandHandlerStatus {
        guard player != nil else { return .noActionableNowPlayingItem }
        pause()
        return .success
    }

    @discardableResult
    func handleTogglePlayPauseCommand() -> MPRemoteCommandHandlerStatus {
        guard player != nil else { return .noActionableNowPlayingItem }
        isPlaying ? pause() : resume()
        return .success
    }

    @discardableResult
    func handleSkipBackwardCommand(interval: TimeInterval) -> MPRemoteCommandHandlerStatus {
        guard player != nil else { return .noActionableNowPlayingItem }
        seek(to: max(0, currentTime - interval))
        return .success
    }

    @discardableResult
    func handleSkipForwardCommand(interval: TimeInterval) -> MPRemoteCommandHandlerStatus {
        guard player != nil else { return .noActionableNowPlayingItem }
        seek(to: currentTime + interval)
        return .success
    }

    @discardableResult
    func handleChangePlaybackPositionCommand(positionTime: TimeInterval) -> MPRemoteCommandHandlerStatus {
        guard player != nil else { return .noActionableNowPlayingItem }
        seek(to: positionTime)
        return .success
    }

    // Runs `body` inline if already on the main thread, otherwise synchronously dispatches it to
    // main. A plain DispatchQueue.main.sync deadlocks if the caller is already on main (which
    // MPRemoteCommandCenter's delivery thread isn't documented to never be) — this is the same
    // status-returning shape addTarget's closures need, so callers can't just fire-and-forget an
    // async block instead.
    private static func onMain<T>(_ body: () -> T) -> T {
        Thread.isMainThread ? body() : DispatchQueue.main.sync(execute: body)
    }

    // Republishes the full Now Playing snapshot — called on play()/pause()/resume()/seek() and on
    // every periodic time-observer tick, so elapsed time keeps advancing on the lock screen and
    // CarPlay's scrubber even though nothing else about the session has changed.
    private func updateNowPlayingInfo() {
        guard let nowPlayingMetadata else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: nowPlayingMetadata.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(playbackSpeed) : 0.0,
        ]
        if let showTitle = nowPlayingMetadata.showTitle {
            info[MPMediaItemPropertyArtist] = showTitle
        }
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        if let artwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // Best-effort: artwork is a Now Playing nicety, so a failed/slow download just leaves the
    // lock screen without art rather than blocking or erroring playback.
    private func fetchArtworkIfNeeded(for metadata: NowPlayingMetadata?) {
        guard let artworkURL = metadata?.artworkURL, artworkURLBeingFetched != artworkURL else { return }
        artworkURLBeingFetched = artworkURL

        URLSession.shared.dataTask(with: artworkURL) { [weak self] data, _, _ in
            let fetchedArtwork = data.flatMap(UIImage.init(data:)).map { image in
                MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                guard let fetchedArtwork else {
                    // A failed fetch (network error, bad data) clears this so a later play() for
                    // the same URL — e.g. the next episode of the same show — retries instead of
                    // being silently skipped forever. A successful fetch leaves it set: it then
                    // doubles as "artwork already fetched," so a same-show replay doesn't
                    // redundantly re-download it.
                    if self.artworkURLBeingFetched == artworkURL {
                        self.artworkURLBeingFetched = nil
                    }
                    return
                }
                // The show may have changed again (or playback stopped) while this was in
                // flight — only apply it if it's still what's actually playing.
                guard self.nowPlayingMetadata?.artworkURL == artworkURL else { return }
                self.artwork = fetchedArtwork
                self.updateNowPlayingInfo()
            }
        }.resume()
    }
}
