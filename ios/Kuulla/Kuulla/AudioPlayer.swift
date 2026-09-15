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

// The subset of WatchNowPlayingState that actually warrants a republish to the watch (#582) —
// deliberately excludes position/duration so the periodic time-observer tick (which updates those
// every second via updateNowPlayingInfo()) doesn't spam WCSession's application context.
private struct WatchNowPlayingStateKey: Equatable {
    let episodeId: String?
    let isPlaying: Bool
    let hasArtwork: Bool

    init(episodeId: String?, isPlaying: Bool, hasArtwork: Bool) {
        self.episodeId = episodeId
        self.isPlaying = isPlaying
        self.hasArtwork = hasArtwork
    }

    init(_ state: WatchNowPlayingState?) {
        episodeId = state?.episodeId
        isPlaying = state?.isPlaying ?? false
        hasArtwork = state?.artworkThumbnail != nil
    }
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

    // Non-nil exactly while `player` is playing an AVMutableComposition built by
    // SpliceCompositionBuilder (#777) rather than the source file directly — translates
    // AVPlayer's own (composition) time to/from source time at every boundary below
    // (currentTime, duration, seek), so chapters, outro-skip, transcript highlighting, and
    // progress sync all keep operating in source time without knowing a splice is involved.
    private var activeTimeMap: CompositionTimeMap?

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
    // the .rate assignment or .spectral pitch wiring in play()/setPlaybackSpeed() were broken.
    var currentPlayerRate: Float? { player?.rate }
    var currentPitchAlgorithm: AVAudioTimePitchAlgorithm? { player?.currentItem?.audioTimePitchAlgorithm }

    // Fires once, on the main queue, when the current item finishes playing naturally (not on a
    // manual pause). A single slot rather than a broadcast mechanism — callers should assign this
    // only at the point they start playback for a specific URL (not merely on screen appearance),
    // so a screen that never presses play can't steal the callback from whichever episode is
    // actually playing in the background.
    var onDidFinishPlaying: ((URL) -> Void)?

    // Fires once per session, a few seconds before the current item's natural end — the signal
    // PlaybackQueue (#683) uses to kick off resolving and preloading the next queue item's audio
    // ahead of time, so a natural finish can swap to an already-buffered player instead of running
    // the full async resolution chain live. Single-slot, assigned-at-play() contract mirrors
    // onDidFinishPlaying exactly, for the same reason (a screen that never presses play can't
    // steal the callback from whichever episode is actually playing).
    var onApproachingEnd: (() -> Void)?

    // Fires once, synchronously from play()/swapToPendingPreload(), whenever the session that
    // just started is playing a spliced composition with a nonzero amount trimmed — carries the
    // real-world seconds saved (source seconds trimmed, adjusted for playback speed) for the
    // caller to credit into DownloadedEpisodeRecord.creditSilenceTimeSavedIfNeeded (#680/#777).
    // Single-slot, assigned-at-play() contract mirrors onDidFinishPlaying/onApproachingEnd:
    // AudioPlayer itself has no SwiftData access to guard "already counted" bookkeeping, so that
    // stays the caller's responsibility.
    var onSpliceApplied: ((_ realSecondsSaved: TimeInterval) -> Void)?

    private var timeObserverToken: Any?
    private var endObserver: NSObjectProtocol?

    // The current session's SmartSpeed processor, purely so play()/removeObservers() have
    // something to reference — its actual memory lifetime is owned by the tap itself (see
    // SmartSpeedProcessor.makeAudioMix's passRetained/release), independent of this property. nil
    // whenever SmartSpeed, Voice Boost, and Trim Silence are all off, so the tap-processing cost
    // is only ever paid when at least one of the three is actually in use.
    private var smartSpeedProcessor: SmartSpeedProcessor?

    private var autoSkipOutroSeconds: TimeInterval = 0
    // Guards against firing the outro skip more than once per playback (the periodic time
    // observer keeps ticking after the skip fires, since the item is merely paused, not
    // deallocated or seeked to its true end).
    private var hasTriggeredOutroSkip = false

    // MARK: - Gapless preload (#683)

    // Seconds of remaining playback at which onApproachingEnd fires. Long enough that a normal
    // network fetch of the next episode's playable URL plus a few seconds of buffering usually
    // finishes before the current item actually ends (closing most of the hard-cut gap, which was
    // otherwise bound by that same network/DB latency happening live at end-of-track); short
    // enough that it doesn't hold a second AVPlayerItem/AVPlayer pair — and its network
    // connection — open for meaningfully longer than necessary.
    static let approachingEndLeadSeconds: TimeInterval = 10

    // Guards onApproachingEnd against firing more than once per session — mirrors
    // hasTriggeredOutroSkip's own guard, for the same reason (the periodic observer keeps
    // ticking after the threshold is crossed).
    private var hasFiredApproachingEnd = false

    // A second, fully inert AVPlayerItem/AVPlayer pair prepared ahead of time for the next queue
    // item, built by preloadNext() and consumed by swapToPendingPreload(). Never assigned to
    // `player`/`currentURL`, and publishes no @Observable state — so it's invisible to the
    // currently-playing session unless and until a caller actually swaps to it. pendingNextItem is
    // kept alongside pendingNextPlayer (rather than read via pendingNextPlayer.currentItem) so the
    // KVO observer below and the swap's identity check both compare against the exact item the
    // observer was attached to.
    private var pendingNextPlayer: AVPlayer?
    private var pendingNextItem: AVPlayerItem?
    private var pendingNextURL: URL?
    private var pendingNextContext: NowPlayingContext?
    private var pendingNextMetadata: NowPlayingMetadata?
    private var pendingNextStartPosition: TimeInterval = 0
    private var pendingNextAutoSkipOutroSeconds: TimeInterval = 0
    private var pendingNextPlaybackSpeed: Float = 1.0
    private var pendingNextSmartSpeedProcessor: SmartSpeedProcessor?
    private var pendingNextStatusObserver: NSKeyValueObservation?
    // Mirrors activeTimeMap/duration for the pending preload — applied to the real properties
    // only once swapToPendingPreload() actually takes over.
    private var pendingNextTimeMap: CompositionTimeMap?
    private var pendingNextSourceDuration: TimeInterval?

    // True once pendingNextItem's KVO status has reached .readyToPlay. Tracked explicitly (rather
    // than read straight off pendingNextItem.status at swap time) so it can also be driven
    // directly by markPendingPreloadReady() in tests, where a fake network URL's AVPlayerItem
    // never actually reaches readyToPlay.
    private(set) var pendingNextIsReady = false

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
    // Last state actually sent to the watch (#582), compared on every updateNowPlayingInfo() call
    // so a plain per-second time-observer tick doesn't spam WCSession's application context —
    // only episode identity, play state, or artwork arriving/changing should trigger a republish.
    private var lastPublishedWatchStateKey: WatchNowPlayingStateKey?
    // Monotonic counter handed to WatchConnectivitySession.publish(nowPlaying:sequence:) so it can
    // discard an out-of-order delivery from an earlier, slower Task (see publishToWatch below).
    private var nowPlayingPublishSequence = 0

    // pathObserver is a test-only seam (mirroring DownloadManager's) — production always uses the
    // real NWPathMonitor-backed default; tests inject a mock to simulate Wi-Fi/cellular
    // transitions deterministically.
    private var interruptionObserver: NSObjectProtocol?
    // Captured at the moment an interruption begins so .ended only resumes what was actually
    // playing — the system's .shouldResume option reflects the session's state, not whether the
    // user had already tapped pause before or during the interruption.
    private var wasPlayingBeforeInterruption = false
    // How far to rewind when auto-resuming after an interruption ends (#710, AntennaPod
    // "rewind on resume") — a call or nav prompt is likely to swallow part of a sentence, so
    // resuming exactly where playback stopped tends to lose the last few words of context.
    private static let interruptionRewindSeconds: TimeInterval = 3

    init(pathObserver: NetworkPathObserving = NWPathMonitorAdapter()) {
        self.pathObserver = pathObserver
        configureAudioSession()
        configureRemoteCommandCenter()
        observeInterruptions()
        self.pathObserver.startObserving { [weak self] isOnWifi in
            DispatchQueue.main.async { self?.isOnWifi = isOnWifi }
        }
    }

    deinit {
        sleepTimer?.invalidate()
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
    }

    // Without this, an interruption (phone call, Siri, another app's audio) leaves the session
    // deactivated once the interruption ends: AVPlayer pauses itself when the interruption
    // begins, but nothing reactivates the session or resumes playback afterwards, so background
    // playback that gets interrupted near a screen lock never comes back (#604).
    private func observeInterruptions() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] notification in
            guard let self,
                  let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue)
            else { return }
            self.handleInterruption(type: type)
        }
    }

    // Pulled out as an internal test seam (mirroring completeGoverningSeek / tickSleepTimer) —
    // AVAudioSession.interruptionNotification can't be posted deterministically in a unit test.
    //
    // Deliberately ignores AVAudioSessionInterruptionOptionKey/.shouldResume entirely (#612): that
    // option is documented as advisory and in practice is inconsistently set by the system for
    // exactly the short, ambient interruptions most likely to fire right around a screen lock
    // (e.g. a notification's system sound) — a real phone call reliably sets it, but plenty of
    // brief system sounds don't, even though resuming afterward is exactly correct. Our own
    // wasPlayingBeforeInterruption is a more reliable signal of user intent than that flag, so
    // .ended resumes whenever we were actually playing, regardless of what the system suggests.
    func handleInterruption(type: AVAudioSession.InterruptionType) {
        switch type {
        case .began:
            // The system has already paused the player and deactivated the session; mirror
            // that in our own state so the UI (play/pause button, lock screen controls)
            // reflects it instead of still claiming isPlaying.
            wasPlayingBeforeInterruption = isPlaying
            isPlaying = false
            updateNowPlayingInfo()
        case .ended:
            // pendingSeekPlayer != nil means play()'s saved-position seek hasn't landed yet —
            // resuming here would race it and could start playback from the wrong position
            // (mirrors pause()'s own pendingSeekPlayer-clearing guard above).
            guard wasPlayingBeforeInterruption, pendingSeekPlayer == nil else { return }
            // Reactivate synchronously here too, ahead of resume()'s own setActive(true): an
            // interruption that ends right as the phone locks gives the app almost no background
            // execution budget, and the OS can suspend the process between this line and resume()
            // actually running — leaving the session inactive and playback silently stuck paused
            // (looks identical to "locking pauses playback"). Blocking main briefly here is safe:
            // this fires once per interruption, not per frame.
            try? AVAudioSession.sharedInstance().setActive(true)
            seek(to: max(0, currentTime - Self.interruptionRewindSeconds))
            resume()
        @unknown default:
            break
        }
    }

    func play(
        url: URL, startPosition: TimeInterval = 0,
        autoSkipIntroSeconds: TimeInterval = 0, autoSkipOutroSeconds: TimeInterval = 0,
        playbackSpeed: Float = 1.0, smartSpeed: Bool = false, voiceBoost: Bool = false, trimSilence: Bool = false,
        volumeOffsetDb: Float = 0, excludedRanges: [SilenceRange] = [],
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

        // A manual play() always makes any outstanding preload stale, whether or not it was ever
        // going to be used — this is a brand-new session, possibly for a completely different
        // episode than whatever nextItem() had in mind when the preload was started.
        discardPendingPreload()

        let (item, timeMap, sourceDuration) = makePlayerItem(url: url, trimSilence: trimSilence, excludedRanges: excludedRanges)
        activeTimeMap = timeMap
        smartSpeedProcessor = makeSmartSpeedProcessorIfNeeded(
            for: item, smartSpeed: smartSpeed, voiceBoost: voiceBoost, trimSilence: trimSilence, volumeOffsetDb: volumeOffsetDb,
            silenceAlreadySpliced: timeMap != nil)

        let newPlayer = AVPlayer(playerItem: item)
        player = newPlayer
        currentURL = url
        duration = sourceDuration ?? 0
        self.autoSkipOutroSeconds = autoSkipOutroSeconds
        self.playbackSpeed = playbackSpeed
        hasTriggeredOutroSkip = false
        hasFiredApproachingEnd = false

        // Only skip the intro on a fresh start (startPosition 0) — a saved resume position
        // means playback already passed the intro once, so it shouldn't be skipped again on
        // every resume.
        let effectiveStartPosition = startPosition > 0 ? startPosition : autoSkipIntroSeconds
        currentTime = effectiveStartPosition
        // Composition time, not source time, is what the player itself needs to seek/start at.
        let playerStartPosition = timeMap?.compositionTime(fromSource: effectiveStartPosition) ?? effectiveStartPosition

        // AVPlayer.seek(to:) is asynchronous — calling play() immediately after would let playback
        // start audibly at 0s and then jump once the seek lands. Deferring the rate-apply to the
        // seek's completion handler makes resume-from-position actually start at that position.
        // Setting .rate rather than calling .play() starts playback at the configured speed
        // directly, instead of starting at 1.0 and then jumping.
        if playerStartPosition > 0 {
            issueGoverningSeek(to: CMTime(seconds: playerStartPosition, preferredTimescale: 600))
        } else {
            newPlayer.rate = playbackSpeed
        }
        isPlaying = true
        nowPlayingContext = context
        applyMetadata(metadata)
        if let timeMap, timeMap.totalTrimmed > 0 {
            onSpliceApplied?(timeMap.totalTrimmed / TimeInterval(playbackSpeed))
        }

        wireUpFreshlyStartedPlayer(item: item, player: newPlayer, url: url)
    }

    // Builds the AVPlayerItem for a play()/preloadNext() session — an AVMutableComposition with
    // the silence spliced out (#777) when trimSilence is on, the file is a local download, and a
    // silence map has already been computed for it; the plain source URL in every other case
    // (streams, unanalyzed downloads, trimSilence off), which keeps SmartSpeedProcessor's
    // real-time rate-based trim as the degraded mode exactly as before this feature existed.
    //
    // Resolves the asset's track/duration synchronously (the deprecated, non-async AVAsset APIs)
    // rather than awaiting loadTracks the way makeSmartSpeedProcessorIfNeeded does for the audio
    // mix: this path only ever runs against an already-downloaded local file, where that read
    // resolves effectively instantly, unlike the general (possibly-remote) asset the audio mix
    // has to handle — the case that motivated going async there (#657). Falls back to the plain
    // URL item on any failure (missing track, non-finite duration, composition build error)
    // rather than failing playback outright, mirroring SmartSpeedProcessor.makeAudioMix's own
    // no-op-on-failure philosophy.
    private func makePlayerItem(
        url: URL, trimSilence: Bool, excludedRanges: [SilenceRange]
    ) -> (item: AVPlayerItem, timeMap: CompositionTimeMap?, sourceDuration: TimeInterval?) {
        guard url.isFileURL, trimSilence, !excludedRanges.isEmpty else {
            return (AVPlayerItem(url: url), nil, nil)
        }
        let asset = AVURLAsset(url: url)
        let sourceDuration = asset.duration.seconds
        guard sourceDuration.isFinite, sourceDuration > 0,
              let track = asset.tracks(withMediaType: .audio).first,
              let (composition, timeMap) = try? SpliceCompositionBuilder.build(
                track: track, sourceDuration: sourceDuration, excludedRanges: excludedRanges)
        else {
            return (AVPlayerItem(url: url), nil, nil)
        }
        return (AVPlayerItem(asset: composition), timeMap, sourceDuration)
    }

    // Builds a SmartSpeedProcessor and wires its silence-detection callbacks + async audioMix
    // assignment for `item`, exactly as play() has always done — pulled out so preloadNext() can
    // build the same wiring for a pending item without duplicating this block. Returns nil (and
    // leaves `item` untouched) when smartSpeed/voiceBoost/trimSilence are all off and
    // volumeOffsetDb is 0, matching play()'s own "only pay the tap-processing cost when actually
    // in use" contract.
    private func makeSmartSpeedProcessorIfNeeded(
        for item: AVPlayerItem, smartSpeed: Bool, voiceBoost: Bool, trimSilence: Bool, volumeOffsetDb: Float = 0,
        silenceAlreadySpliced: Bool = false
    ) -> SmartSpeedProcessor? {
        // Pitch correction so spoken-word content speeds up without the chipmunk effect a naive
        // rate change would produce. .spectral (a phase vocoder) rather than .timeDomain: the
        // time-domain stretcher overlaps ever-shorter waveform grains as the rate climbs and
        // audibly warbles/stutters from ~2x up — the "sounds funny at 3x" symptom in
        // docs/audio-engine-research.md — while spectral stays smooth across the whole 0.5x-3x
        // preset range (and the faster silence-skip rate on top of it) for a CPU cost that's
        // negligible on any iOS 17 device. Applied unconditionally (not just when SmartSpeed/
        // VoiceBoost/TrimSilence are on) since every session, preloaded or not, can have its
        // rate changed via setPlaybackSpeed().
        item.audioTimePitchAlgorithm = .spectral

        // A splice-only session (trimSilence the sole reason this would otherwise fire) needs no
        // tap at all once the composition has already removed the silence.
        guard smartSpeed || voiceBoost || (trimSilence && !silenceAlreadySpliced) || volumeOffsetDb != 0 else { return nil }

        let processor = SmartSpeedProcessor(
            smartSpeed: smartSpeed, voiceBoost: voiceBoost, trimSilence: trimSilence, volumeOffsetDb: volumeOffsetDb,
            silenceAlreadySpliced: silenceAlreadySpliced)
        // Captures item weakly so a later play()/swapToPendingPreload() that replaces self.player
        // (and drops this item) can't have this stale session's detector adjust the new player's
        // rate out from under it — the identity check below is the real guard, this just avoids
        // retaining a dead item purely to compare against.
        processor.onSilenceStateChanged = { [weak self, weak item] isSilent, itemTime in
            DispatchQueue.main.async {
                // isPlaying/pendingSeekPlayer guards mirror setPlaybackSpeed's own: a paused
                // session must not have this resume it by setting a nonzero rate, and a
                // saved-position seek still in flight must not have its deferred-start-until-
                // seeked behavior defeated by a rate change landing early.
                guard let self, let item, let player = self.player, player.currentItem === item,
                      self.isPlaying, self.pendingSeekPlayer == nil
                else { return }
                guard !isSilent else {
                    player.rate = SmartSpeedProcessor.silenceSkipRate(forPlaybackSpeed: self.playbackSpeed)
                    return
                }
                player.rate = self.playbackSpeed
                // The tap reports "sound resumed" ahead of the speaker, but this rate restore
                // lands ~100-300 ms later (main-thread hop plus AVPlayer re-timing its pipeline),
                // and everything rendered in between played at the skip rate — the first word or
                // two after every pause, at up to 6x. `itemTime` is the exact position sound
                // resumed at, so if the output has already run past it, jump back there and
                // replay those words at the normal rate. A rewind of a few tens of ms isn't
                // worth the seek's own tiny discontinuity, hence the threshold.
                if Self.shouldRewindAfterSilence(playerTime: player.currentTime().seconds, resumeItemTime: itemTime) {
                    player.seek(
                        to: CMTime(seconds: itemTime, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                }
            }
        }
        // Accumulates real-world time saved by silence-trimming (#680) into the lifetime,
        // on-device counter — see LocalSettings.lifetimeSilenceTimeSavedSeconds's own doc
        // comment for why this is device-local rather than synced. Dispatched to main (mirroring
        // onSilenceStateChanged above) since this reads self.playbackSpeed, which is otherwise
        // only ever touched on main.
        processor.onSilenceRunCompleted = { [weak self] runItemDuration in
            DispatchQueue.main.async {
                guard let self else { return }
                LocalSettings.addSilenceTimeSaved(
                    Self.silenceTimeSaved(runItemDuration: runItemDuration, playbackSpeed: self.playbackSpeed))
            }
        }
        // Setting audioMix asynchronously (rather than blocking play() on it, #657) races the
        // item's own internal buffering in principle, but not in practice: the item can't
        // reach readyToPlay — and so can't start actually decoding/rendering audio — without
        // itself first resolving the asset's tracks, which is the same underlying load this
        // await is waiting on. Should that ever lose the race (e.g. an already-cached local
        // file), the outcome is silent degradation to "no SmartSpeed effect" for that one
        // playback session, not a crash — consistent with makeAudioMix's own no-op-on-failure
        // philosophy above. Weak item mirrors the guard above: a later play() that replaces
        // self.player (and drops this item) makes the assignment a no-op instead of touching a
        // dropped item.
        Task { @MainActor [weak item] in
            guard let item else { return }
            item.audioMix = await processor.makeAudioMix(for: item)
        }
        return processor
    }

    // How far past the resume point the output must have run before it's worth seeking back —
    // below this the lost audio is a fraction of a syllable and the seek's discontinuity would
    // be the more audible of the two.
    static let silenceRewindThreshold: TimeInterval = 0.05

    // Whether the rate-restore latency after a silence skip cost enough audio to replay. Pure so
    // the decision is unit-testable; `playerTime` is the output position when the restore lands,
    // `resumeItemTime` the tap's position when sound came back. A non-finite player time (no
    // current item, indefinite time) or an unknown resume time never rewinds.
    static func shouldRewindAfterSilence(playerTime: TimeInterval, resumeItemTime: TimeInterval) -> Bool {
        playerTime.isFinite && resumeItemTime > 0 && playerTime - resumeItemTime > silenceRewindThreshold
    }

    // Real-world seconds a confirmed silent run of `runItemDuration` item-seconds saved (#680):
    // listening through it took runItemDuration / silenceSkipRate(forPlaybackSpeed:), where
    // without the skip it would have taken runItemDuration / playbackSpeed — the difference is
    // what was saved. Pure so the accounting is unit-testable against the capped skip rate.
    static func silenceTimeSaved(runItemDuration: TimeInterval, playbackSpeed: Float) -> TimeInterval {
        let speed = TimeInterval(playbackSpeed)
        let skipRate = TimeInterval(SmartSpeedProcessor.silenceSkipRate(forPlaybackSpeed: playbackSpeed))
        return runItemDuration / speed - runItemDuration / skipRate
    }

    // Attaches the periodic time observer and end-of-item observer that every freshly-started
    // player session needs — shared by play() and swapToPendingPreload() so a gapless swap gets
    // exactly the same bookkeeping a fresh play() call would, rather than a hand-duplicated subset
    // of it that could silently drift out of sync.
    private func wireUpFreshlyStartedPlayer(item: AVPlayerItem, player: AVPlayer, url: URL) {
        timeObserverToken = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            guard let self else { return }
            self.currentTime = self.activeTimeMap?.sourceTime(fromComposition: time.seconds) ?? time.seconds
            // A composition's own duration is the shortened, spliced one — duration was already
            // set to the source file's real duration in play()/swapToPendingPreload() and must
            // stay there for every consumer (progress bar, outro-skip threshold) that assumes
            // source time.
            if self.activeTimeMap == nil, let itemDuration = player.currentItem?.duration.seconds, itemDuration.isFinite {
                self.duration = itemDuration
            }
            self.checkAutoSkipOutro(url: url)
            self.checkApproachingEnd()
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
        // A manual pause always wins, including one that happens mid-interruption (Control Center
        // is still reachable during some interruption types): without this, handleInterruption's
        // .ended case would still see wasPlayingBeforeInterruption == true from before the
        // interruption began and resume playback the user just explicitly paused.
        wasPlayingBeforeInterruption = false
        updateNowPlayingInfo()
    }

    func resume() {
        // Reactivates the session before setting the rate, not just on the automatic
        // post-interruption path — an interruption that ends without .shouldResume, or a route
        // change, can leave AVAudioSession inactive while isPlaying is still false. Without this,
        // a manual resume (Lock Screen, Control Center, in-app button) sets .rate and flips
        // isPlaying, which keeps the periodic time observer (and Now Playing progress) advancing
        // normally, but with the session inactive no audio reaches the hardware (#612).
        //
        // Synchronous rather than dispatched off main (unlike configureAudioSession()'s initial
        // activation): every caller here (remote command center via Self.onMain, in-app button)
        // already runs on main, and resume() is most often invoked right after a screen lock or
        // interruption — exactly when the app has almost no background execution budget. A
        // dispatched setActive(true) can lose the race with the OS suspending the process, leaving
        // the session inactive and playback silently stuck even though isPlaying reads true (looks
        // like "tapping play from the lock screen does nothing"). Mirrors the same fix already
        // applied to handleInterruption's .ended case. Blocking main briefly here is safe: this
        // fires once per tap, not per frame.
        //
        // Deliberately not the iOS 17+ activate(options:completionHandler:) / async activate() API
        // (#656): both return before the session is actually active and report success later via a
        // completion/continuation, which is the same "dispatched off main" shape that caused #612 —
        // the OS can suspend the process before that completion runs, leaving .rate set and
        // isPlaying true with no active session. There's no async variant that blocks until the
        // session is confirmed active, so the synchronous call — and the main-thread warning it
        // logs — is intentional here, not an oversight.
        try? AVAudioSession.sharedInstance().setActive(true)
        // .rate rather than .play() so resuming doesn't silently reset speed back to 1.0.
        player?.rate = playbackSpeed
        isPlaying = true
        updateNowPlayingInfo()
    }

    func seek(to time: TimeInterval) {
        currentTime = time
        // `time` is always source time (every caller — scrub, chapter tap, transcript tap,
        // interruption rewind — reasons about the episode's own timeline); translate to
        // composition time only for the actual AVPlayer call when a splice is in effect.
        let playerTarget = activeTimeMap?.compositionTime(fromSource: time) ?? time
        let cmTime = CMTime(seconds: playerTarget, preferredTimescale: 600)
        // A manual seek can move well away from (or back into) the approaching-end window, and any
        // outstanding preload was resolved for "whatever plays after wherever the user was" — no
        // longer trustworthy once they've jumped around. Discarding here (rather than only on the
        // next natural finish or fresh play()) also stops holding open a second AVPlayerItem/
        // AVPlayer pair — and its network connection — for a transition the user may no longer be
        // heading toward.
        hasFiredApproachingEnd = false
        discardPendingPreload()
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
        // updateNowPlayingInfo()'s watch-publish only fires on episode/play-state/artwork
        // changes (see publishNowPlayingStateToWatchIfChanged), none of which a seek touches —
        // so the position jump needs this explicit, unconditional republish.
        republishNowPlayingToWatch()
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
            // Playback is intentionally stopping here — any preload started for "what plays
            // next" is now wasted, so free it instead of leaving a second AVPlayer/network
            // connection open for no reason.
            discardPendingPreload()
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

    // Fires onApproachingEnd once remaining playback (duration - currentTime) crosses
    // approachingEndLeadSeconds — mirrors checkAutoSkipOutro's own threshold-crossing shape, just
    // against a fixed lead time instead of a per-show configured outro.
    private func checkApproachingEnd() {
        guard !hasFiredApproachingEnd,
              Self.shouldFireApproachingEnd(currentTime: currentTime, duration: duration, leadSeconds: Self.approachingEndLeadSeconds)
        else { return }
        hasFiredApproachingEnd = true
        onApproachingEnd?()
    }

    // Pulled out as a pure function so the boundary condition is unit-testable without a real,
    // ticking AVPlayer — mirrors shouldTriggerOutroSkip exactly. Duration not yet known (<= 0)
    // means there's nothing to compare against, so it never fires prematurely before the item has
    // actually loaded.
    static func shouldFireApproachingEnd(currentTime: TimeInterval, duration: TimeInterval, leadSeconds: TimeInterval) -> Bool {
        guard duration > 0 else { return false }
        return duration - currentTime <= leadSeconds
    }

    // MARK: - Gapless preload (#683)

    // Builds a second, inert AVPlayerItem/AVPlayer pair for `url` and lets it start buffering
    // toward .readyToPlay, without touching `player`/`currentURL` or publishing any @Observable
    // change — the currently-playing session is completely unaffected until (and unless)
    // swapToPendingPreload() is actually called. Mirrors play()'s own item/player construction
    // (including the .spectral pitch algorithm and SmartSpeedProcessor tap wiring) so the
    // eventual swap needs no further setup beyond what wireUpFreshlyStartedPlayer already does.
    // Discards any previous pending preload first — callers (PlaybackQueue) are expected to
    // request at most one at a time per session, but this makes that a guarantee rather than an
    // assumption.
    func preloadNext(
        url: URL, startPosition: TimeInterval = 0, autoSkipIntroSeconds: TimeInterval = 0,
        playbackSpeed: Float = 1.0, autoSkipOutroSeconds: TimeInterval = 0,
        smartSpeed: Bool = false, voiceBoost: Bool = false, trimSilence: Bool = false,
        volumeOffsetDb: Float = 0, excludedRanges: [SilenceRange] = [],
        context: NowPlayingContext? = nil, metadata: NowPlayingMetadata? = nil
    ) {
        discardPendingPreload()

        let (item, timeMap, sourceDuration) = makePlayerItem(url: url, trimSilence: trimSilence, excludedRanges: excludedRanges)
        let processor = makeSmartSpeedProcessorIfNeeded(
            for: item, smartSpeed: smartSpeed, voiceBoost: voiceBoost, trimSilence: trimSilence, volumeOffsetDb: volumeOffsetDb,
            silenceAlreadySpliced: timeMap != nil)

        let newPlayer = AVPlayer(playerItem: item)
        // Deliberately left at rate 0 — preloading only buffers the item toward readyToPlay, it
        // must not audibly start playing anything until swapToPendingPreload() takes over.
        newPlayer.rate = 0

        // Mirrors play()'s own "skip the intro only on a fresh start" rule — a next-queue-item
        // preload is always a fresh start (there's no "resume this episode" path into
        // preloadNext), so startPosition (a saved resume position, e.g. the user previously
        // stopped partway through this same episode from a different session) always wins when
        // present.
        let effectiveStartPosition = startPosition > 0 ? startPosition : autoSkipIntroSeconds
        let playerStartPosition = timeMap?.compositionTime(fromSource: effectiveStartPosition) ?? effectiveStartPosition

        pendingNextPlayer = newPlayer
        pendingNextItem = item
        pendingNextURL = url
        pendingNextContext = context
        pendingNextMetadata = metadata
        pendingNextStartPosition = effectiveStartPosition
        pendingNextAutoSkipOutroSeconds = autoSkipOutroSeconds
        pendingNextPlaybackSpeed = playbackSpeed
        pendingNextSmartSpeedProcessor = processor
        pendingNextTimeMap = timeMap
        pendingNextSourceDuration = sourceDuration
        pendingNextIsReady = false

        // Issued immediately (unlike play()'s deferred-until-seek-completes rate apply) rather
        // than reproducing play()'s full governing-seek machinery: this seek has minutes, not
        // milliseconds, to land before swapToPendingPreload() actually applies a nonzero rate to
        // it, so the audible "start at 0 then jump" race play()'s own comment describes doesn't
        // apply here in practice.
        if playerStartPosition > 0 {
            newPlayer.seek(to: CMTime(seconds: playerStartPosition, preferredTimescale: 600))
        }

        // AVPlayerItem.status isn't guaranteed to update on main, and every pending* property is
        // otherwise only ever read/written on main (mirroring issueGoverningSeek's own dispatch)
        // — hop explicitly rather than relying on incidental timing.
        pendingNextStatusObserver = item.observe(\.status, options: [.new]) { [weak self] observedItem, _ in
            DispatchQueue.main.async {
                guard let self, self.pendingNextItem === observedItem else { return }
                self.pendingNextIsReady = observedItem.status == .readyToPlay
            }
        }
    }

    // Internal (not private) so tests can simulate the preloaded item reaching readyToPlay
    // without waiting on a real KVO status transition — a fake network URL's AVPlayerItem never
    // actually resolves in a unit test. Mirrors completeGoverningSeek / tickSleepTimer's own test
    // seams for the same reason (AVFoundation state that can't be driven deterministically here).
    func markPendingPreloadReady() {
        pendingNextIsReady = true
    }

    // Cheap, synchronous check for whether a ready preload exists for `url` — exposed so a caller
    // (PlaybackQueue) can decide whether to use it without reaching into any of AudioPlayer's
    // private preload state directly.
    func hasPendingPreload(for url: URL) -> Bool {
        pendingNextIsReady && pendingNextURL == url
    }

    // Swaps the current session over to the already-prepared preload, applying exactly the same
    // bookkeeping a fresh play() call would (Now Playing info, remote command wiring via
    // updateNowPlayingInfo/applyMetadata, periodic time + end-of-item observers) via the same
    // wireUpFreshlyStartedPlayer helper play() itself uses — so a gapless swap is indistinguishable
    // from a fresh play() to every other part of the app. Returns false (and changes nothing) when
    // there's no preload, or it hasn't reached readyToPlay yet, or its player/item have gone out of
    // sync somehow — callers must fall back to the full, slow play() path in that case.
    @discardableResult
    func swapToPendingPreload() -> Bool {
        guard pendingNextIsReady,
              let newPlayer = pendingNextPlayer, let item = pendingNextItem, newPlayer.currentItem === item,
              let url = pendingNextURL
        else { return false }

        let context = pendingNextContext
        let metadata = pendingNextMetadata
        let startPosition = pendingNextStartPosition
        let autoSkipOutroSeconds = pendingNextAutoSkipOutroSeconds
        let playbackSpeed = pendingNextPlaybackSpeed
        let processor = pendingNextSmartSpeedProcessor
        let timeMap = pendingNextTimeMap
        let sourceDuration = pendingNextSourceDuration
        // Clears the pending-preload slot before this session's own state is applied below —
        // wireUpFreshlyStartedPlayer's periodic observer can in principle tick synchronously
        // enough to want a clean slate, and there is nothing left in the pending slot worth
        // keeping regardless of how the rest of this method proceeds.
        discardPendingPreload()

        removeObservers()
        // This is a brand-new governing session, exactly like play()'s own — any saved-position
        // seek from the previous session is moot.
        pendingSeekPlayer = nil
        pendingSeekGeneration += 1

        player = newPlayer
        currentURL = url
        activeTimeMap = timeMap
        // Set optimistically, mirroring play()'s own currentTime = effectiveStartPosition — the
        // preload's seek (issued back in preloadNext(), with a multi-second head start) has
        // almost always already landed by the time a swap happens, so unlike play() there's no
        // need to defer this behind a governing-seek completion.
        currentTime = startPosition
        duration = sourceDuration ?? 0
        self.autoSkipOutroSeconds = autoSkipOutroSeconds
        self.playbackSpeed = playbackSpeed
        self.smartSpeedProcessor = processor
        hasTriggeredOutroSkip = false
        hasFiredApproachingEnd = false
        isPlaying = true
        nowPlayingContext = context
        applyMetadata(metadata)
        if let timeMap, timeMap.totalTrimmed > 0 {
            onSpliceApplied?(timeMap.totalTrimmed / TimeInterval(playbackSpeed))
        }

        newPlayer.rate = playbackSpeed

        wireUpFreshlyStartedPlayer(item: item, player: newPlayer, url: url)
        return true
    }

    // Drops the pending preload, if any — called whenever it's known to be stale: a fresh play()
    // call (any manual play, including one for a completely different episode), a successful swap
    // (nothing left to hold onto), and the sleep timer consuming a finish instead of advancing.
    // Internal (not private) so PlaybackQueue can also drop it explicitly when it clears or re-arms
    // a session (e.g. the user backs out of the list a preload was started for) without waiting on
    // a subsequent play() call to clean it up.
    func discardPendingPreload() {
        pendingNextStatusObserver = nil
        pendingNextPlayer = nil
        pendingNextItem = nil
        pendingNextURL = nil
        pendingNextContext = nil
        pendingNextMetadata = nil
        pendingNextStartPosition = 0
        pendingNextAutoSkipOutroSeconds = 0
        pendingNextPlaybackSpeed = 1.0
        pendingNextSmartSpeedProcessor = nil
        pendingNextTimeMap = nil
        pendingNextSourceDuration = nil
        pendingNextIsReady = false
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
        // setActive(true) is synchronous and can block the calling thread (AVFoundation warns about
        // this at runtime when called on the main thread). AVAudioSession has no async activation
        // API on iOS — only on watchOS — so the fix is to hop off the main thread before calling it.
        DispatchQueue.global(qos: .userInitiated).async {
            try? session.setActive(true)
        }
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
            // nowPlayingMetadata is never actually reset to nil today, so this branch is
            // currently dead — but if a future "stop/unload" path adds that, remember this
            // early return also skips publishNowPlayingStateToWatchIfChanged() below, so the
            // watch would keep showing the last episode forever instead of clearing (#582).
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
        publishNowPlayingStateToWatchIfChanged()
    }

    // Unconditional — used by seek() (which doesn't change episode identity, play state, or
    // artwork, so publishNowPlayingStateToWatchIfChanged()'s dedup key would otherwise miss it)
    // and by KuullaApp's reachability watcher, which needs the current snapshot resent the moment
    // the watch reconnects regardless of whether anything changed while it was unreachable.
    func republishNowPlayingToWatch() {
        let state = currentWatchNowPlayingState()
        lastPublishedWatchStateKey = WatchNowPlayingStateKey(state)
        publishToWatch(state)
    }

    // Computes the dedup key from the raw properties first — deliberately *before* building the
    // full WatchNowPlayingState — so the per-second periodic-time-observer tick (which also
    // routes through updateNowPlayingInfo()) doesn't pay for an artwork resize + JPEG encode on
    // every tick just to discard the result when nothing watch-relevant actually changed.
    private func publishNowPlayingStateToWatchIfChanged() {
        let key = WatchNowPlayingStateKey(
            episodeId: nowPlayingContext?.episodeId, isPlaying: isPlaying, hasArtwork: artwork != nil)
        guard key != lastPublishedWatchStateKey else { return }
        lastPublishedWatchStateKey = key
        publishToWatch(currentWatchNowPlayingState())
    }

    // Assigns a sequence number synchronously (on whatever thread every other AudioPlayer method
    // already assumes is main — see the file-wide informal main-thread contract, e.g. onMain())
    // before handing off to the actor. Unstructured `Task {}` creation order isn't guaranteed to
    // match the order those Tasks reach WatchConnectivitySession's serialized queue, so without
    // this a rapid pause-then-seek (or similar back-to-back state change) could have its two
    // publishes land out of order and leave the watch showing the stale one; the actor uses the
    // sequence to always keep the newest snapshot, regardless of delivery order.
    private func publishToWatch(_ state: WatchNowPlayingState?) {
        nowPlayingPublishSequence += 1
        let sequence = nowPlayingPublishSequence
        Task { await WatchConnectivitySession.shared.publish(nowPlaying: state, sequence: sequence) }
    }

    // Internal (not private) so tests can assert on the built snapshot directly, mirroring
    // tickSleepTimer's own test-seam convention above.
    func currentWatchNowPlayingState() -> WatchNowPlayingState? {
        guard let nowPlayingContext, let nowPlayingMetadata else { return nil }
        return WatchNowPlayingState(
            episodeId: nowPlayingContext.episodeId,
            showId: nowPlayingContext.showId,
            title: nowPlayingMetadata.title,
            showTitle: nowPlayingMetadata.showTitle,
            artworkThumbnail: artwork.flatMap { Self.downsampledArtworkThumbnail($0) },
            position: currentTime,
            duration: duration,
            isPlaying: isPlaying)
    }

    // Downsamples to a small square JPEG so the watch payload stays tiny — WCSession's
    // application context is meant for small "current state" snapshots, not full-resolution
    // images. artwork's own image(at:) ignores the requested size (see fetchArtworkIfNeeded
    // above, which always returns the original), so the resize has to happen here instead.
    static func downsampledArtworkThumbnail(_ artwork: MPMediaItemArtwork, maxDimension: CGFloat = 80) -> Data? {
        guard let image = artwork.image(at: CGSize(width: maxDimension, height: maxDimension)),
            image.size.width > 0, image.size.height > 0
        else { return nil }
        let scale = min(maxDimension / image.size.width, maxDimension / image.size.height, 1)
        let targetSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: targetSize)) }
        return resized.jpegData(compressionQuality: 0.6)
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
