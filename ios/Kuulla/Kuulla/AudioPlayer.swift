import AVFoundation

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

    // Fires once, on the main queue, when the current item finishes playing naturally (not on a
    // manual pause). A single slot rather than a broadcast mechanism — callers should assign this
    // only at the point they start playback for a specific URL (not merely on screen appearance),
    // so a screen that never presses play can't steal the callback from whichever episode is
    // actually playing in the background.
    var onDidFinishPlaying: ((URL) -> Void)?

    private var timeObserverToken: Any?
    private var endObserver: NSObjectProtocol?

    private var autoSkipOutroSeconds: TimeInterval = 0
    // Guards against firing the outro skip more than once per playback (the periodic time
    // observer keeps ticking after the skip fires, since the item is merely paused, not
    // deallocated or seeked to its true end).
    private var hasTriggeredOutroSkip = false

    init() {
        configureAudioSession()
    }

    func play(
        url: URL, startPosition: TimeInterval = 0,
        autoSkipIntroSeconds: TimeInterval = 0, autoSkipOutroSeconds: TimeInterval = 0
    ) {
        removeObservers()

        let item = AVPlayerItem(url: url)
        let newPlayer = AVPlayer(playerItem: item)
        player = newPlayer
        currentURL = url
        duration = 0
        self.autoSkipOutroSeconds = autoSkipOutroSeconds
        hasTriggeredOutroSkip = false

        // Only skip the intro on a fresh start (startPosition 0) — a saved resume position
        // means playback already passed the intro once, so it shouldn't be skipped again on
        // every resume.
        let effectiveStartPosition = startPosition > 0 ? startPosition : autoSkipIntroSeconds
        currentTime = effectiveStartPosition

        // AVPlayer.seek(to:) is asynchronous — calling play() immediately after would let playback
        // start audibly at 0s and then jump once the seek lands. Deferring play() to the seek's
        // completion handler makes resume-from-position actually start at that position.
        if effectiveStartPosition > 0 {
            newPlayer.seek(to: CMTime(seconds: effectiveStartPosition, preferredTimescale: 600)) { [weak newPlayer] _ in
                newPlayer?.play()
            }
        } else {
            newPlayer.play()
        }
        isPlaying = true

        timeObserverToken = newPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            guard let self else { return }
            self.currentTime = time.seconds
            if let itemDuration = newPlayer.currentItem?.duration.seconds, itemDuration.isFinite {
                self.duration = itemDuration
            }
            self.checkAutoSkipOutro(url: url)
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
            self.onDidFinishPlaying?(url)
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func resume() {
        player?.play()
        isPlaying = true
    }

    func seek(to time: TimeInterval) {
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        player?.seek(to: cmTime)
        currentTime = time
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
}
