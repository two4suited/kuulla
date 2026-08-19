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

    init() {
        configureAudioSession()
    }

    func play(url: URL, startPosition: TimeInterval = 0) {
        removeObservers()

        let item = AVPlayerItem(url: url)
        let newPlayer = AVPlayer(playerItem: item)
        player = newPlayer
        currentURL = url
        duration = 0
        currentTime = startPosition

        // AVPlayer.seek(to:) is asynchronous — calling play() immediately after would let playback
        // start audibly at 0s and then jump once the seek lands. Deferring play() to the seek's
        // completion handler makes resume-from-position actually start at that position.
        if startPosition > 0 {
            newPlayer.seek(to: CMTime(seconds: startPosition, preferredTimescale: 600)) { [weak newPlayer] _ in
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
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
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
