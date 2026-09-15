import SwiftData
import SwiftUI

// @MainActor so every Task {} created inside this view's methods (e.g. startProgressTracking's
// polling loop, the onDidFinishPlaying callback) inherits main-actor isolation rather than running
// on an arbitrary executor — audioPlayer's properties are only ever mutated on the main queue
// (AudioPlayer's periodic time observer and NotificationCenter observer both use queue: .main), so
// reading them off-main would be a data race.
@MainActor
struct EpisodeDetailView: View {
    let showId: String
    let episodeId: String
    // Non-nil when this screen was reached from a playlist (manual or dynamic) — starting
    // playback here arms PlaybackQueue by playlist id so finishing the episode auto-advances
    // through that playlist's current order (#532, generalised to dynamic playlists by #629).
    var playlistId: String?
    // Non-nil when this screen was reached from a show's episode list or New Episodes, which
    // already have their ordered snapshot on hand — arms PlaybackQueue directly with it rather
    // than a playlist re-fetch (#629). Mutually exclusive with playlistId in practice (a route
    // carries one or the other).
    var list: PlaybackList?
    // Set when this screen was reached via a list row's play button rather than a plain
    // row tap — starts playback as soon as load() resolves, instead of requiring a second tap
    // here.
    var autoPlayOnAppear = false

    @Environment(\.episodeSyncEngine) private var syncEngine
    @Environment(\.playlistSyncEngine) private var playlistSyncEngine
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    @State private var episode: Episode?
    @State private var show: Show?
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var audioPlayer = AudioPlayer.shared

    @State private var stateRecord: EpisodeStateRecord?
    // Non-nil while the "resume from your other device" prompt (#241) is shown — set when
    // evaluateResumePrompt finds a synced position another device wrote that differs enough from
    // this device's own (ahead or behind).
    @State private var resumePrompt: CrossDeviceResume.Prompt?
    // The synced record's updatedAt the user has already answered the resume prompt for, so a
    // return-from-background re-check doesn't re-ask about that same cross-device position — but
    // a genuinely newer write from another device (different updatedAt) still prompts. Reset in
    // load() when a different episode opens.
    @State private var answeredResumeUpdatedAt: Date?
    // Non-nil while the mid-playback "now playing on another device" banner (#242) is shown.
    @State private var handoffBanner: CrossDeviceHandoff.Banner?
    // The synced UpdatedAt of the last remote write we've already surfaced via the handoff
    // banner, so a later poll doesn't re-raise the banner for the exact same write.
    @State private var lastSurfacedHandoffUpdatedAt: Date?
    // Set when the user dismisses the handoff banner — suppresses it for the rest of this
    // playback session (cleared when this device (re)starts the episode, or on load()).
    @State private var handoffDismissed = false
    @State private var downloadStatus: DownloadStatus?
    // Fetched lazily (best-effort) once the episode is known to advertise a transcript; nil until
    // then, and stays nil if the episode has no transcript or the fetch fails.
    @State private var transcript: TranscriptDocument?
    // Cached rather than recomputed inline in the view body — resolvedPlaybackURL(for:) does a
    // synchronous SwiftData fetch, and episodeHeader also reads audioPlayer.currentTime (via
    // activeChapter/ChapterScrubber), which re-renders every second during playback. Recomputed
    // only when the episode loads or the download status changes (loadLocalState), the only two
    // things that can actually change which URL resolves.
    @State private var resolvedAudioURL: URL?
    @State private var progressTrackingTask: Task<Void, Never>?
    @State private var isShowingAddToPlaylist = false
    @State private var isShowingSleepTimer = false
    // Non-nil while the in-app browser sheet for a chapter link (e.g. a sponsor URL) is open.
    @State private var chapterLinkURL: URL?
    @State private var autoSkipIntroSeconds = 0
    @State private var autoSkipOutroSeconds = 0
    @State private var playbackSpeed: Float = 1.0
    @State private var smartSpeed = false
    @State private var voiceBoost = false
    @State private var volumeOffsetDb: Float = 0
    @State private var trimSilence = false
    // Global-only (no per-show override), per docs/downloads-storage-settings.md.
    @State private var autoDeleteRule: AutoDeleteRule = .never
    @State private var playbackSpeedSaveTask: Task<Void, Never>?
    @State private var playbackSpeedSaveError: String?
    // Bumped on every cyclePlaybackSpeed() call; lets a save task tell whether it's still the
    // latest one after waiting on its predecessor, so superseded intermediate values are
    // coalesced away instead of being sent at all.
    @State private var playbackSpeedSaveVersion = 0

    private let catalogClient = PodcastCatalogClient()
    private let settingsClient = SettingsClient()
    private let playlistClient = PlaylistClient()

    private var status: EpisodeStatus { EpisodeStatus(record: stateRecord) }

    private var completedButtonTitle: String {
        switch status {
        case .played: "Mark as Unplayed"
        case .autoPlayed: "Restore"
        case .new, .inProgress: "Mark as Played"
        }
    }

    // A non-preset value (e.g. synced from elsewhere, or a value outside the current preset set)
    // still needs a readable label — fixed-precision formatting matches PlaybackSpeedOption.label
    // rather than showing a raw float that can render as something like "1.20000005x".
    private var playbackSpeedLabel: String {
        if let option = PlaybackSpeedOption(rawValue: playbackSpeed) {
            return option.label
        }
        return "\(playbackSpeed.formatted(.number.precision(.fractionLength(0...2))))x"
    }

    // Reflects whichever sleep timer mode (if any) is currently active — a global AudioPlayer
    // state, same caveat as isPlaying(_:) above: this doesn't scope to this screen's episode,
    // since the sleep timer stops whatever's actually playing.
    private var sleepTimerButtonTitle: String {
        if audioPlayer.sleepTimerEndOfEpisodeEnabled {
            return "Sleep Timer: End of Episode"
        }
        if let remaining = SleepTimerSheet.formatRemaining(audioPlayer.sleepTimerRemainingSeconds) {
            return "Sleep Timer: \(remaining)"
        }
        return "Sleep Timer"
    }

    // AudioPlayer is a single shared instance, so isPlaying/currentURL are global, not scoped to
    // this screen's episode — a plain `audioPlayer.isPlaying` check would show "Pause" (and treat
    // a tap as pause-this-episode) while a *different* episode is actually playing.
    private func isPlaying(_ url: URL) -> Bool {
        audioPlayer.isPlaying && audioPlayer.currentURL == url
    }

    // Same "is this screen's episode the one actually loaded" gate the rest of this view uses —
    // nil whenever this episode isn't the one currently playing/paused in AudioPlayer, since
    // currentTime/duration would otherwise belong to whatever different episode played last.
    private func activeChapter(for episode: Episode, audioURL: URL) -> EpisodeChapter? {
        guard audioPlayer.currentURL == audioURL, let chapters = episode.chapters, !chapters.isEmpty else {
            return nil
        }
        guard let index = ChapterScrubber.activeChapterIndex(chapters: chapters, currentTime: audioPlayer.currentTime) else {
            return nil
        }
        return chapters[index]
    }

    // Pulled out of body — inlining this HStack there pushed the surrounding VStack's single
    // expression past what the type-checker could resolve in reasonable time.
    @ViewBuilder
    private func artworkRow(showArtworkUrl: String?, chapterArtworkUrl: String?) -> some View {
        if showArtworkUrl != nil || chapterArtworkUrl != nil {
            HStack(spacing: 12) {
                if let showArtworkUrl {
                    EpisodeArtworkImage(urlString: showArtworkUrl)
                }

                // Alongside (not replacing) the episode artwork — falls back to nothing extra
                // shown when the active chapter has no image of its own.
                if let chapterArtworkUrl {
                    EpisodeArtworkImage(urlString: chapterArtworkUrl)
                }
            }
        }
    }

    // Pulled out of body — inlining these directly in the ScrollView's VStack made the type-checker
    // time out on the combined expression (artworkRow/ChapterScrubber pushed it over the edge).
    // Split into two (rather than one big episodeContent) for the same reason.
    @ViewBuilder
    private func episodeHeader(_ episode: Episode) -> some View {
        // Read from the cached resolvedAudioURL (refreshed in loadLocalState) rather than calling
        // resolvedPlaybackURL(for:) here — this function reads audioPlayer.currentTime below
        // (via activeChapter/ChapterScrubber), which re-renders every second during playback, and
        // resolvedPlaybackURL(for:) does a synchronous SwiftData fetch that shouldn't repeat that
        // often for a value that only actually changes on load or a download-status change.
        let audioURL = resolvedAudioURL
        let currentChapter: EpisodeChapter? = audioURL.flatMap { activeChapter(for: episode, audioURL: $0) }

        artworkRow(showArtworkUrl: show?.artworkUrl, chapterArtworkUrl: currentChapter?.imageUrl)

        HStack(alignment: .firstTextBaseline) {
            Text(episode.title)
                .font(.kuullaTitle(22, relativeTo: .title2))
            Spacer()
            StatusBadge(status: status)
        }

        HStack(spacing: 4) {
            if let publishedAt = episode.publishedAt {
                Text(publishedAt.formatted(date: .abbreviated, time: .omitted))
            }
            if episode.publishedAt != nil && episode.duration != nil {
                Text("·")
            }
            if let duration = episode.duration {
                Text(EpisodeFormatting.formatDuration(duration))
            }
        }
        .font(.kuullaMono(12))
        .foregroundStyle(KuullaColor.textMuted)

        if let audioURL {
            // Play is the one large, prominent action (docs/brand.md §9 — lime is reserved for
            // it). Everything else — download, speed, sleep, mark-played, add-to-playlist — sits
            // in a compact icon row below at a deliberately smaller visual weight.
            Button {
                togglePlayback(url: audioURL)
            } label: {
                Label(isPlaying(audioURL) ? "Pause" : "Play", systemImage: isPlaying(audioURL) ? "pause.fill" : "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            episodeControlRow(episode)

            // AudioPlayer.shared is a single global instance, so the message must be
            // matched against this screen's own audioURL — otherwise a message left
            // over from blocking a different episode's remote stream would keep
            // showing here after merely navigating to this one.
            if let streamBlockedMessage = audioPlayer.streamBlockedMessage, audioPlayer.streamBlockedURL == audioURL {
                Text(streamBlockedMessage)
                    .font(.caption)
                    .foregroundStyle(KuullaColor.danger)
                Text("Or download this episode above to play it without Wi-Fi.")
                    .font(.caption)
                    .foregroundStyle(KuullaColor.textMuted)
            }

            // A remote stream's AVPlayerItem reached .failed (#781) — a local file failure instead
            // falls back to the stream automatically (see startPlayback's onLocalFileFailed
            // wiring) and never sets this, so reaching here always means there's nothing left to
            // fall back to. Matched against this screen's own audioURL for the same reason as
            // streamBlockedMessage above.
            if let playbackErrorMessage = audioPlayer.playbackErrorMessage, audioPlayer.playbackErrorURL == audioURL {
                Text(playbackErrorMessage)
                    .font(.caption)
                    .foregroundStyle(KuullaColor.danger)
            }

            // A newer position came in from another device while this one keeps playing (#242):
            // offer the jump rather than yanking playback. Gated on this screen's episode being
            // the one actively playing — it's a *playback* handoff, so it shouldn't linger once
            // this device is paused.
            if isPlaying(audioURL), let banner = handoffBanner {
                HStack(spacing: 8) {
                    Button {
                        Task { await jumpToHandoff(banner) }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .accessibilityHidden(true)
                            Text("Now playing on another device — tap to jump to \(EpisodeFormatting.formatDuration(TimeInterval(banner.targetPositionSeconds)))")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .buttonStyle(.bordered)

                    Button {
                        dismissHandoffBanner()
                    } label: {
                        Image(systemName: "xmark")
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Dismiss")
                }
                .font(.caption)
            }

            // Same "is this screen's episode the one actually loaded" gate as
            // isPlaying(_:) above — AudioPlayer's currentTime/duration are otherwise
            // whatever a different episode last left them at.
            if audioPlayer.currentURL == audioURL {
                ChapterScrubber(
                    currentTime: audioPlayer.currentTime,
                    duration: audioPlayer.duration,
                    chapters: episode.chapters ?? [],
                    onSeek: { audioPlayer.seek(to: $0) },
                    onOpenLink: { chapterLinkURL = $0 })
            }

            // Shown whenever the feed advertised a transcript and one was fetched — not gated on
            // this episode being the one currently loaded. Playback-position sync and tap-to-seek
            // only act live when it is; otherwise a tap starts this episode at that point.
            if episode.transcriptUrl != nil, let segments = transcript?.segments, !segments.isEmpty {
                let isActiveEpisode = audioPlayer.currentURL == audioURL
                TranscriptView(
                    segments: segments,
                    currentTime: isActiveEpisode ? audioPlayer.currentTime : 0,
                    onSeek: { seekTranscript(to: $0, audioURL: audioURL) })
            }
        }
    }

    // Compact secondary-action row shown directly under Play: speed (a value pill), download,
    // sleep timer, mark-played, add-to-playlist. Deliberately low visual weight next to the
    // full-width lime Play button — icon-only, neutral chrome, lime tint only on the one or two
    // that are genuinely in an active state (docs/brand.md §9).
    @ViewBuilder
    private func episodeControlRow(_ episode: Episode) -> some View {
        HStack(spacing: Space.sm) {
            Button {
                cyclePlaybackSpeed()
            } label: {
                Text(playbackSpeedLabel)
                    .font(.kuullaMono(13))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(playbackSpeed == 1.0 ? KuullaColor.textMuted : KuullaColor.signalInk)
            }
            .buttonStyle(.plain)
            // While loadPlaybackSettings() is still in flight, playbackSpeed hasn't been
            // resolved from settings yet — cycling from an unresolved value would itself get
            // overwritten the moment that fetch lands.
            .disabled(isLoading)
            .modifier(EpisodeControlChrome(isActive: playbackSpeed != 1.0))
            .accessibilityLabel("Playback speed, \(playbackSpeedLabel)")
            .accessibilityHint("Cycles to the next speed")

            DownloadButton(episode: episode, status: downloadStatus, onDidFinish: loadLocalState, fillsContainer: true)
                .modifier(EpisodeControlChrome())

            Button {
                isShowingSleepTimer = true
            } label: {
                Image(systemName: sleepTimerActive ? "moon.zzz.fill" : "moon.zzz")
                    .font(.system(size: 16))
                    .foregroundStyle(sleepTimerActive ? KuullaColor.signalInk : KuullaColor.textMuted)
            }
            .buttonStyle(.plain)
            .modifier(EpisodeControlChrome(isActive: sleepTimerActive))
            .accessibilityLabel(sleepTimerButtonTitle)

            Button {
                Task { await handleCompletedButtonTapped() }
            } label: {
                Image(systemName: isCompletedState ? "checkmark.circle.fill" : "checkmark.circle")
                    .font(.system(size: 16))
                    .foregroundStyle(isCompletedState ? KuullaColor.signalInk : KuullaColor.textMuted)
            }
            .buttonStyle(.plain)
            .modifier(EpisodeControlChrome(isActive: isCompletedState))
            .accessibilityLabel(completedButtonTitle)

            Button {
                isShowingAddToPlaylist = true
            } label: {
                Image(systemName: "text.badge.plus")
                    .font(.system(size: 16))
                    .foregroundStyle(KuullaColor.textMuted)
            }
            .buttonStyle(.plain)
            .modifier(EpisodeControlChrome())
            .accessibilityLabel("Add to Playlist")
        }

        if let playbackSpeedSaveError {
            Text(playbackSpeedSaveError)
                .font(.caption)
                .foregroundStyle(KuullaColor.danger)
        }
    }

    // True whenever this episode is marked played (manually or auto-played) — drives the
    // checkmark's filled/lime treatment, the state the old text button carried in its label.
    private var isCompletedState: Bool {
        switch status {
        case .played, .autoPlayed: true
        case .new, .inProgress: false
        }
    }

    // Any sleep timer mode running — a countdown or end-of-episode.
    private var sleepTimerActive: Bool {
        audioPlayer.sleepTimerEndOfEpisodeEnabled || audioPlayer.sleepTimerRemainingSeconds != nil
    }

    @ViewBuilder
    private func episodeShowNotes(_ episode: Episode) -> some View {
        if let description = episode.description, !description.isEmpty {
            Text("Show notes")
                .font(.kuullaTitle(17, relativeTo: .headline))
                .padding(.top, 8)
            Text(description)
        } else {
            Text("No show notes available for this episode.")
                .foregroundStyle(.secondary)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let episode {
                    episodeHeader(episode)
                    episodeShowNotes(episode)
                } else if let loadError {
                    Text(loadError)
                        .foregroundStyle(KuullaColor.danger)
                } else if !isLoading {
                    Text("Episode not found.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .overlay {
            if isLoading {
                ProgressView()
            }
        }
        .navigationTitle(episode?.title ?? "Episode")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isShowingAddToPlaylist) {
            AddToPlaylistSheet(episodeId: episodeId, showId: showId)
        }
        .sheet(isPresented: $isShowingSleepTimer) {
            SleepTimerSheet()
        }
        .sheet(isPresented: Binding(get: { chapterLinkURL != nil }, set: { if !$0 { chapterLinkURL = nil } })) {
            if let chapterLinkURL {
                // SFSafariViewController's URL can't be changed after init, and
                // updateUIViewController is a no-op — without .id, SwiftUI can reuse the same
                // underlying controller across presentations and show a stale URL if the user
                // opens a different chapter's link later. .id forces a fresh controller whenever
                // the URL changes.
                SafariView(url: chapterLinkURL)
                    .id(chapterLinkURL)
            }
        }
        .task(id: episodeId) {
            await load()
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Returning from background is one of the two moments #241 calls out for the resume
            // prompt — another device may have moved this episode while we were away. Await our
            // own syncNow() rather than racing KuullaApp's detached one, so the re-check runs
            // against the freshly pulled position instead of stale local state.
            guard newPhase == .active else { return }
            Task {
                // Only need local state to be *fresh*, not to push anything — so don't force an
                // extra round when KuullaApp's own .active sync is already in flight.
                await syncEngine?.syncNow(requestFollowUpIfSyncing: false)
                loadLocalState()
                // loadLocalState() reads through this view's @Environment(\.modelContext), which
                // isn't guaranteed to observe the pull syncNow() just applied through the
                // engine's own context — re-read stateRecord from that context so the resume
                // check sees the freshly pulled position. (URL/download state stays from
                // loadLocalState.)
                if let refreshed = await syncEngine?.currentState(episodeId: episodeId) {
                    stateRecord = refreshed
                }
                evaluateResumePrompt()
            }
        }
        .alert(
            "Resume from your other device?",
            isPresented: Binding(get: { resumePrompt != nil }, set: { if !$0 { resumePrompt = nil } }),
            presenting: resumePrompt
        ) { prompt in
            // `prompt` is captured by value here, so the choice still applies even though
            // dismissing the alert clears `resumePrompt` before this async work runs.
            Button("Resume") {
                let sourceUpdatedAt = stateRecord?.updatedAt
                Task { await resolveResumePrompt(prompt, sourceUpdatedAt: sourceUpdatedAt, resume: true) }
            }
            Button("Not now", role: .cancel) {
                let sourceUpdatedAt = stateRecord?.updatedAt
                Task { await resolveResumePrompt(prompt, sourceUpdatedAt: sourceUpdatedAt, resume: false) }
            }
        } message: { prompt in
            Text("You left off at \(EpisodeFormatting.formatDuration(TimeInterval(prompt.otherDevicePositionSeconds))) on another device.")
        }
        .onDisappear {
            progressTrackingTask?.cancel()
            progressTrackingTask = nil
        }
    }

    private func load() async {
        episode = nil
        show = nil
        resumePrompt = nil
        answeredResumeUpdatedAt = nil
        handoffBanner = nil
        lastSurfacedHandoffUpdatedAt = nil
        handoffDismissed = false
        transcript = nil
        loadError = nil
        isLoading = true

        // Paint instantly from the on-device catalog cache (#534's pattern), then refresh from
        // the network below — this is what already-known episodes (Now Playing, a visible list
        // row) skip the network latency for (#614).
        episode = CatalogCache.episode(showId: showId, episodeId: episodeId, in: modelContext)
        show = CatalogCache.show(id: showId, in: modelContext)
        if episode != nil {
            loadLocalState()
        }

        // getEpisode and getShow don't depend on each other, so they're kicked off concurrently
        // instead of sequentially (#614) — each still only costs the latency of one round trip.
        async let episodeResult = catalogClient.getEpisode(showId: showId, episodeId: episodeId)
        async let showResult = try? catalogClient.getShow(id: showId)

        do {
            episode = try await episodeResult
        } catch {
            if !Task.isCancelled {
                loadError = "Something went wrong while loading this episode. Please try again."
            }
        }

        // Resolved before awaiting the show fetch below (rather than after) — resolvedAudioURL
        // gates whether Play/Pause and the download button render at all, so a slow/failed
        // getShow shouldn't delay or block starting playback when the episode's own audio URL is
        // already known.
        loadLocalState()

        // Best-effort: only feeds the lock screen/CarPlay Now Playing artist + artwork, so a
        // failure here shouldn't block or error out episode loading itself.
        show = await showResult

        // This fetch races the play button the same way loadPlaybackSettings' does below: a tap
        // before it resolves starts playback with no show title/artwork (audioPlayer.play's
        // metadata argument is only as complete as `show` was at that moment). Correct the
        // session that's already running rather than leaving it stuck without artwork/artist for
        // the rest of this episode. Reads the cached resolvedAudioURL (rather than calling
        // resolvedPlaybackURL(for:) fresh) so this stays consistent with loadLocalState's pin to
        // an already-loaded remote session.
        if let episode, let audioURL = resolvedAudioURL, audioPlayer.currentURL == audioURL {
            audioPlayer.updateMetadata(NowPlayingMetadata(title: episode.title, showTitle: show?.title, artworkURL: show?.artworkUrl.flatMap(URL.init(string:))))
        }

        // Skip fetching playback settings when the episode itself failed to load — playback
        // isn't possible without an episode, so there's no reason to wait on (or surface errors
        // from) a settings fetch that won't be used.
        if episode != nil {
            await loadPlaybackSettings()
        }

        // autoPlayOnAppear only ever applies to the load this .task(id: episodeId) triggered for
        // a freshly-opened screen — skip if this episode is already playing (e.g. the user
        // backgrounded and returned) so a stray autoplay tap can't pause an in-progress session.
        // Not skipped when it's merely loaded-but-paused: togglePlayback's resume branch (checked
        // via audioPlayer.currentURL == url) still needs to run then, or tapping a row's play
        // button for a paused episode would silently do nothing.
        if autoPlayOnAppear, let resolvedAudioURL, !isPlaying(resolvedAudioURL) {
            togglePlayback(url: resolvedAudioURL)
        }
        isLoading = false

        // After the episode and its local state are both resolved: offer to pick up from a
        // position another device synced for this episode — ahead of or behind this one (#241).
        evaluateResumePrompt()

        // After isLoading flips — the transcript is supplementary and the API may take a moment to
        // normalize/cache it on a cold hit, so it shouldn't hold up rendering the rest of the
        // screen. .task(id: episodeId) cancels this if the user navigates away first.
        await loadTranscript()
    }

    private func loadTranscript() async {
        guard let episode, episode.transcriptUrl != nil else {
            return
        }
        let fetched = try? await catalogClient.getEpisodeTranscript(showId: showId, episodeId: episodeId)
        // The @State box is shared across view-value re-creations, so a fetch that resolves after
        // the user navigated to another episode (this task cancelled, load() re-run) would
        // otherwise write that episode's transcript over the new one's.
        guard !Task.isCancelled else { return }
        transcript = fetched
    }

    private func loadLocalState() {
        stateRecord = (try? modelContext.fetch(Self.stateDescriptor(for: episodeId)))?.first
        downloadStatus = DownloadStatus.statusMap(for: [episodeId], in: modelContext)[episodeId]

        // Pinned to the episode's remote URL rather than switched to a newly-completed local
        // download, whenever AudioPlayer already has that remote URL loaded (playing or paused)
        // — checked against episode.audioUrl directly, not the previous resolvedAudioURL, so this
        // also covers navigating away and back to a screen whose download finished in the
        // background (resolvedAudioURL starts nil again on load(), so comparing against it alone
        // would miss that case). Otherwise every isPlaying(_:)/currentURL == audioURL check in
        // this view would stop matching an in-flight session (the UI would flip back to "Play"
        // and hide the scrubber/chapters despite audio still loaded/playing). The next reload
        // once playback has moved off this episode's remote URL picks up the local file normally.
        if let episode, let remoteURL = URL(string: episode.audioUrl), audioPlayer.currentURL == remoteURL {
            resolvedAudioURL = remoteURL
            return
        }
        resolvedAudioURL = episode.flatMap(resolvedPlaybackURL(for:))
    }

    // Shows the cross-device resume prompt (#241) when this episode's synced position was last
    // written by a different device, more recently than this device last played and far enough
    // from this device's own position to matter — whether that's further ahead or rewound behind.
    // Never interrupts a session already running for this episode, and re-evaluating is cheap and
    // idempotent — answering the prompt records the remote write's updatedAt, which suppresses
    // re-prompts until a genuinely newer one arrives.
    private func evaluateResumePrompt() {
        guard episode != nil, let record = stateRecord else {
            resumePrompt = nil
            return
        }
        // Already answered the prompt for this exact remote write — don't re-ask on a
        // return-from-background re-check. A newer write from another device has a different
        // updatedAt and still gets through.
        if record.updatedAt == answeredResumeUpdatedAt {
            resumePrompt = nil
            return
        }
        if let audioURL = resolvedAudioURL, audioPlayer.currentURL == audioURL {
            resumePrompt = nil
            return
        }
        resumePrompt = CrossDeviceResume.prompt(
            syncedPositionSeconds: record.positionSeconds,
            syncedUpdatedAt: record.updatedAt,
            syncedDeviceId: record.deviceId,
            completed: record.completed,
            currentDeviceId: DeviceIdentity.current,
            lastLocalPositionSeconds: record.lastLocalPositionSeconds,
            lastLocalPlaybackAt: record.lastLocalPlaybackAt)
    }

    // "Resume" adopts the other device's position and starts playback there. "Not now" keeps
    // this device's own last position — persisted (LWW, per docs/sync-conventions.md) so the
    // two devices converge, but only when this device actually has local progress to keep;
    // declining on an episode this device has never played leaves the synced position untouched
    // rather than pushing a zero that would wipe the other device's progress.
    private func resolveResumePrompt(
        _ prompt: CrossDeviceResume.Prompt, sourceUpdatedAt: Date?, resume: Bool
    ) async {
        resumePrompt = nil
        // Remember which remote write this answer was for, so a background round-trip doesn't
        // re-prompt for the same one — but a newer write from another device still can.
        answeredResumeUpdatedAt = sourceUpdatedAt

        if resume {
            await persist(positionSeconds: prompt.otherDevicePositionSeconds, completed: false)
            if let audioURL = resolvedAudioURL {
                startPlayback(url: audioURL, startPosition: TimeInterval(prompt.otherDevicePositionSeconds))
            }
        } else if prompt.localPositionSeconds > 0 {
            await persist(positionSeconds: prompt.localPositionSeconds, completed: false)
        }
    }

    // Best-effort: these are playback niceties, not core functionality, so a failure here
    // silently falls back to defaults (no auto-skip, normal speed) rather than surfacing an
    // error to the user. Fetched together since both resolve show-override-else-global from the
    // same pair of settings documents.
    private func loadPlaybackSettings() async {
        async let userSettings = try? settingsClient.getSettings()
        async let showSettings = try? settingsClient.getShowSettings(showId: showId)
        let (user, show) = await (userSettings, showSettings)

        guard !Task.isCancelled else { return }
        autoSkipIntroSeconds = show?.autoSkipIntroSeconds ?? user?.autoSkipIntroSeconds ?? 0
        autoSkipOutroSeconds = show?.autoSkipOutroSeconds ?? user?.autoSkipOutroSeconds ?? 0
        playbackSpeed = show?.playbackSpeed ?? user?.playbackSpeed ?? 1.0
        // Same fetch-races-the-play-button race as playbackSpeed below, but unlike it there's no
        // AudioPlayer.setSmartSpeed to correct an already-running session — the MTAudioProcessingTap
        // is only ever installed at AVPlayerItem construction time in play(), and there's no way to
        // add one to a session already in progress without rebuilding the item (an audible glitch
        // worse than the race itself). This matches autoSkipIntroSeconds/autoSkipOutroSeconds below,
        // which have the same "resolved-after-play-already-started" limitation and no live fix
        // either — accepted, not something this diff introduces.
        smartSpeed = show?.smartSpeed ?? user?.smartSpeed ?? false
        voiceBoost = show?.voiceBoost ?? user?.voiceBoost ?? false
        volumeOffsetDb = show?.volumeOffsetDb ?? user?.volumeOffsetDb ?? 0
        trimSilence = show?.trimSilence ?? user?.trimSilence ?? false
        autoDeleteRule = Self.resolvedAutoDeleteRule(show: show, user: user)

        // This fetch races the play button: a tap before it resolves starts playback at the
        // 1.0 fallback (audioPlayer.play's own default), since togglePlayback reads whatever
        // playbackSpeed currently holds. If that happened, apply the now-resolved speed to the
        // session that's already running rather than leaving it stuck at the fallback for the
        // rest of this episode. Reads the cached resolvedAudioURL, same reason as in load() above.
        if let audioURL = resolvedAudioURL, audioPlayer.currentURL == audioURL {
            audioPlayer.setPlaybackSpeed(playbackSpeed)
        }
    }

    // Prefers a completed local download over the remote URL, so offline playback (and playback
    // on a poor connection) doesn't re-stream a file already on disk. Used everywhere this view
    // needs "the URL identifying this episode's audio" — both to actually start playback and to
    // compare against audioPlayer.currentURL — so the two notions never diverge: passing the
    // local URL into play() while some other call site still compared against the remote one
    // would make isPlaying/currentURL checks silently stop matching.
    private func resolvedPlaybackURL(for episode: Episode) -> URL? {
        let record = downloadRecord(for: episode.id)
        return Self.resolvedPlaybackURL(audioUrlString: episode.audioUrl, downloadRecord: record, downloadsDirectory: DownloadManager.downloadsDirectory())
    }

    // Pulled out as a pure function so the "local download wins" resolution logic is
    // unit-testable without needing a real SwiftData ModelContext or the download manager's
    // on-disk directory. `localFileExists` is injectable (rather than calling FileManager
    // directly) so tests can exercise the "record says complete but the file is gone" fallback
    // without touching the real filesystem.
    nonisolated static func resolvedPlaybackURL(
        audioUrlString: String, downloadRecord: DownloadedEpisodeRecord?, downloadsDirectory: URL?,
        localFileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL? {
        if let downloadRecord, downloadRecord.status == .complete, !downloadRecord.localFilePath.isEmpty,
           let downloadsDirectory {
            let localURL = downloadsDirectory.appendingPathComponent(downloadRecord.localFilePath)
            // A record can outlive its file (OS eviction, manual cleanup elsewhere, a bug) —
            // trusting it unconditionally would hand AVPlayer a URL that fails to load with no
            // fallback, instead of just streaming like an episode that was never downloaded.
            if localFileExists(localURL) {
                return localURL
            }
        }
        return URL(string: audioUrlString)
    }

    private static func stateDescriptor(for episodeId: String) -> FetchDescriptor<EpisodeStateRecord> {
        FetchDescriptor<EpisodeStateRecord>(predicate: #Predicate { $0.id == episodeId })
    }

    private func togglePlayback(url: URL) {
        if isPlaying(url) {
            audioPlayer.pause()
            stopProgressTracking()
            Task { await persistProgress(completed: false) }
        } else if audioPlayer.currentURL == url {
            audioPlayer.resume()
            startProgressTracking()
        } else {
            startPlayback(url: url, startPosition: TimeInterval(stateRecord?.positionSeconds ?? 0))
        }
    }

    // Fully replaces whatever's playing with this episode at `startPosition`. Split out of
    // togglePlayback so a transcript tap on an episode that isn't loaded yet can start it at the
    // tapped segment rather than at the saved resume position.
    private func startPlayback(url: URL, startPosition: TimeInterval) {
        // A fresh session on this device: let the handoff banner (#242) surface again if another
        // device takes over later, even if it was dismissed during the previous session.
        handoffDismissed = false

        // Arm (or disarm) auto-advance for this session (#532, generalised by #629): a list
        // snapshot from ShowDetailView/FeedView arms directly; a playlist (manual or dynamic) arms
        // by id, fetching its ordered items; anything else forgets any queue a previous session
        // armed.
        if let list {
            PlaybackQueue.shared.begin(list: list, currentEpisodeId: episodeId)
        } else if let playlistId {
            Task { await PlaybackQueue.shared.begin(playlistId: playlistId, currentEpisodeId: episodeId) }
        } else {
            PlaybackQueue.shared.clear()
        }

        // Pulled out so a local-file playback failure (#781) can re-run exactly this same wiring/
        // play() call against the episode's stream URL instead of a hand-duplicated copy of it.
        func startPlayback(url: URL, startPosition: TimeInterval) {
            // Keeps resolvedAudioURL in sync with whatever AudioPlayer is actually playing —
            // critical for the fallback-replay case: without this, isPlaying(audioURL)/
            // togglePlayback(url:) elsewhere in this view would keep comparing against the
            // original (now-failed) local URL after AudioPlayer.currentURL has already moved to
            // the stream URL, showing "Play" instead of "Pause" and, on tap, restarting playback
            // from that same broken local file all over again.
            resolvedAudioURL = url
            // Assigned only when actually starting playback for this URL (not merely on screen
            // appearance) — AudioPlayer has one completion-callback slot shared across the app,
            // and starting playback here always fully replaces whatever was playing before, so
            // tying the callback to this exact moment keeps it pointed at whichever episode is
            // actually playing rather than being silently stolen by a screen that never pressed
            // play.
            audioPlayer.onDidFinishPlaying = { finishedURL in
                guard finishedURL == url else { return }
                self.stopProgressTracking()
                Task {
                    await self.persistProgress(completed: true)
                    // No-op unless this session was started from a manual playlist — then it
                    // removes the finished episode and starts the next one (#532).
                    await PlaybackQueue.shared.handleNaturalFinish(finishedEpisodeId: self.episodeId)
                }
            }
            DownloadedEpisodeRecord.wireSpliceCredit(episodeId: episodeId, modelContainer: modelContext.container, on: audioPlayer)
            audioPlayer.play(
                url: url, startPosition: startPosition,
                autoSkipIntroSeconds: TimeInterval(autoSkipIntroSeconds), autoSkipOutroSeconds: TimeInterval(autoSkipOutroSeconds),
                playbackSpeed: playbackSpeed, smartSpeed: smartSpeed, voiceBoost: voiceBoost, trimSilence: trimSilence,
                volumeOffsetDb: volumeOffsetDb, excludedRanges: DownloadedEpisodeRecord.silenceMapRanges(from: downloadRecord(for: episodeId)),
                context: NowPlayingContext(showId: showId, episodeId: episodeId, playlistId: playlistId),
                metadata: episode.map { episode in
                    NowPlayingMetadata(
                        title: episode.title, showTitle: show?.title,
                        artworkURL: show?.artworkUrl.flatMap(URL.init(string:)))
                })
            startProgressTracking()
        }

        // Reassigned unconditionally, mirroring onDidFinishPlaying's own single-slot contract
        // above — AudioPlayer.shared is a singleton, so leaving a nil-episode session's play()
        // call without this (e.g. episode not yet loaded) would let a *previous* session's
        // onLocalFileFailed (a different episode, stream URL, and replay closure) stay armed and
        // fire against this one's local-file failure.
        if let episode {
            DownloadedEpisodeRecord.wireLocalFileFailureFallback(
                episodeId: episodeId, streamURLString: episode.audioUrl, modelContainer: modelContext.container,
                on: audioPlayer, replay: startPlayback)
        } else {
            audioPlayer.onLocalFileFailed = nil
        }
        startPlayback(url: url, startPosition: startPosition)
    }

    // Small shared fetch so startPlayback doesn't repeat resolvedPlaybackURL(for:)'s own
    // FetchDescriptor construction just to also get at the silence map.
    private func downloadRecord(for episodeId: String) -> DownloadedEpisodeRecord? {
        let descriptor = FetchDescriptor<DownloadedEpisodeRecord>(predicate: #Predicate { $0.id == episodeId })
        return try? modelContext.fetch(descriptor).first
    }

    // A transcript segment tap: seek if this episode is already loaded, otherwise start it at
    // that point.
    private func seekTranscript(to position: TimeInterval, audioURL: URL) {
        if audioPlayer.currentURL == audioURL {
            audioPlayer.seek(to: position)
        } else {
            startPlayback(url: audioURL, startPosition: position)
        }
    }

    // Cycles through the common speed presets (wrapping back to the first after the last),
    // applying the change live to whatever's currently playing and saving it as the new global
    // default. A value outside the presets (e.g. a synced override from elsewhere) starts the
    // cycle from the slowest preset rather than crashing on a missing match.
    private func cyclePlaybackSpeed() {
        let options = PlaybackSpeedOption.allCases.sorted { $0.rawValue < $1.rawValue }
        let currentIndex = options.firstIndex { $0.rawValue == playbackSpeed } ?? -1
        let next = options[(currentIndex + 1) % options.count]

        playbackSpeed = next.rawValue
        // AudioPlayer is shared across detail screens — only push the live rate change when
        // this screen's episode is the one actually playing, otherwise a tap here would change
        // the speed of whatever different episode happens to be playing in the background. Reads
        // the cached resolvedAudioURL, same reason as in load() above.
        if let audioURL = resolvedAudioURL, audioPlayer.currentURL == audioURL {
            audioPlayer.setPlaybackSpeed(next.rawValue)
        }

        savePlaybackSpeed(next.rawValue)
    }

    // Cancelling the previous Task only stops waiting on its result locally — it doesn't retract
    // a PUT already on the wire, and the endpoint is a plain read-then-upsert, so two in-flight
    // requests could still land out of order and leave a stale speed persisted. Chaining each
    // save behind the previous one (awaiting it before sending) keeps requests in flight one at a
    // time and in order; the version check after that wait then coalesces away anything that's
    // been superseded by a newer cycle before it would even be sent, so only the latest value
    // a user settles on ever reaches the network.
    private func savePlaybackSpeed(_ value: Float) {
        playbackSpeedSaveVersion += 1
        let requestVersion = playbackSpeedSaveVersion
        let previousTask = playbackSpeedSaveTask
        playbackSpeedSaveTask = Task {
            await previousTask?.value
            guard requestVersion == playbackSpeedSaveVersion else { return }

            playbackSpeedSaveError = nil
            do {
                _ = try await settingsClient.updatePlaybackSpeed(value)
            } catch {
                if requestVersion == playbackSpeedSaveVersion {
                    playbackSpeedSaveError = "Something went wrong while saving your default speed."
                }
            }
        }
    }

    private func startProgressTracking() {
        stopProgressTracking()
        progressTrackingTask = Task {
            while !Task.isCancelled {
                // Deliberately longer than SyncEngine's own debounce window (5s, SyncEngine.swift):
                // recordChanged() restarts that debounce on every write, so ticking at exactly the
                // debounce interval would perpetually re-arm it and could starve the actual push for
                // as long as playback continues. A longer interval here lets each debounce fire
                // before the next local write arrives.
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled else { return }
                // Check *before* persisting this tick's local position: persistProgress()
                // overwrites the local record's positionSeconds with where this device is, which
                // would mask a remote jump that the last sync pulled in (#242). By the previous
                // tick's debounced push has round-tripped, so the record already reflects any
                // newer position another device wrote.
                await checkForHandoff()
                await persistProgress(completed: false)
            }
        }
    }

    // If a newer position from another device has landed in the local store for the episode
    // that's currently playing, raise the non-disruptive handoff banner (#242). Never seeks on
    // its own — the user taps the banner for that.
    private func checkForHandoff() async {
        guard !handoffDismissed else { return }
        guard let syncEngine, let audioURL = resolvedAudioURL, audioPlayer.currentURL == audioURL else { return }
        // Detached snapshot read through the engine's own context — the one server pulls are
        // applied to; this view's @Environment context isn't guaranteed to see those writes yet.
        guard let record = await syncEngine.currentState(episodeId: episodeId) else { return }
        handoffBanner = CrossDeviceHandoff.banner(
            syncedPositionSeconds: record.positionSeconds,
            syncedUpdatedAt: record.updatedAt,
            syncedDeviceId: record.deviceId,
            completed: record.completed,
            currentDeviceId: DeviceIdentity.current,
            currentPlaybackPositionSeconds: Int(audioPlayer.currentTime),
            lastSurfacedUpdatedAt: lastSurfacedHandoffUpdatedAt)
    }

    private func jumpToHandoff(_ banner: CrossDeviceHandoff.Banner) async {
        lastSurfacedHandoffUpdatedAt = banner.sourceUpdatedAt
        handoffBanner = nil
        audioPlayer.seek(to: TimeInterval(banner.targetPositionSeconds))
        // Claim the position for this device so the two converge and the banner doesn't
        // immediately reappear for the same remote write.
        await persist(positionSeconds: banner.targetPositionSeconds, completed: false)
    }

    private func dismissHandoffBanner() {
        lastSurfacedHandoffUpdatedAt = handoffBanner?.sourceUpdatedAt
        handoffBanner = nil
        handoffDismissed = true
    }

    private func stopProgressTracking() {
        progressTrackingTask?.cancel()
        progressTrackingTask = nil
    }

    private func handleCompletedButtonTapped() async {
        if status == .autoPlayed {
            await restoreAutoPlayed()
        } else {
            await toggleCompleted()
        }
    }

    private func restoreAutoPlayed() async {
        stopProgressTracking()
        guard let syncEngine else { return }
        // Use the returned record directly rather than loadLocalState() — that re-fetches through
        // this view's own @Environment(\.modelContext), a different instance than the one the
        // write above just saved through (same hazard persist() avoids below).
        if let restored = await syncEngine.restoreAutoPlayed(episodeId: episodeId) {
            stateRecord = restored
            CatalogCache.recordEpisodeStateChange(
                episodeId: episodeId, showId: restored.showId, completed: restored.completed,
                positionSeconds: restored.positionSeconds, in: modelContext)
        }
    }

    private func toggleCompleted() async {
        let newCompleted = status != .played
        if newCompleted {
            stopProgressTracking()
        }
        let position = newCompleted ? Int(episode?.duration ?? 0) : (stateRecord?.positionSeconds ?? 0)
        await persist(positionSeconds: position, completed: newCompleted)
        // #569: persist() is shared with the natural-finish path (persistProgress(completed:
        // true), called right before PlaybackQueue.handleNaturalFinish's own removal), so the
        // playlist cleanup lives here rather than in persist() itself — this manual toggle is the
        // only path that needs it, and putting it in persist() would double the network work on
        // every natural finish for no benefit.
        await PlaylistCleanup.removeFromManualPlaylists(
            episodeId: episodeId, completed: newCompleted,
            playlistSyncEngine: playlistSyncEngine, playlistClient: playlistClient)
    }

    private func persistProgress(completed: Bool) async {
        let position = Int(audioPlayer.currentTime)
        // Promotes a tick/pause report to completed once playback is within the near-end
        // threshold of the episode's duration (#704), so an episode isn't left stuck
        // "in progress" forever just because a listener didn't sit through its trailing
        // outro/credits.
        let isCompleted = completed || EpisodeProgress.isNearEnd(
            positionSeconds: position, duration: audioPlayer.duration,
            thresholdSeconds: EpisodeProgress.nearEndThresholdSeconds)

        // A periodic tick always reports completed: false — it must never downgrade a record that
        // was just marked completed (via natural finish or the manual toggle), since a tick can
        // still be in flight right after either of those events.
        if !isCompleted && stateRecord?.completed == true {
            return
        }

        guard position > 0 || isCompleted else { return }
        await persist(positionSeconds: position, completed: isCompleted)
    }

    private func persist(positionSeconds: Int, completed: Bool) async {
        guard let syncEngine else { return }
        let updatedAt = Date()
        do {
            try await syncEngine.write { context in
                let descriptor = Self.stateDescriptor(for: episodeId)
                if let existing = try context.fetch(descriptor).first {
                    existing.showId = showId
                    existing.positionSeconds = positionSeconds
                    existing.completed = completed
                    existing.updatedAt = updatedAt
                    // Every call into persist() is a manual write path (playback progress, the
                    // completed toggle) — restoreAutoPlayed() is the only path that clears the
                    // flag on an auto-played episode, so any write reaching here always resets it.
                    existing.autoPlayed = false
                    // This device is the writer, so record where *it* played to — the cross-device
                    // resume prompt (#241) compares against this to detect another device moving on.
                    existing.lastLocalPositionSeconds = positionSeconds
                    existing.lastLocalPlaybackAt = updatedAt
                    existing.isDirty = true
                } else {
                    context.insert(EpisodeStateRecord(
                        id: episodeId, showId: showId, positionSeconds: positionSeconds,
                        completed: completed, updatedAt: updatedAt, isDirty: true,
                        lastLocalPositionSeconds: positionSeconds, lastLocalPlaybackAt: updatedAt))
                }
            }
        } catch {
            // The mutation closure's own fetch failed, so nothing was written — don't update
            // stateRecord to reflect values that were never actually persisted.
            assertionFailure("Failed to persist episode state: \(error)")
            return
        }
        // Set directly from the values just written rather than re-reading through modelContext:
        // that's a different ModelContext instance than the one syncEngine.write just saved
        // through, and isn't guaranteed to observe the write synchronously.
        stateRecord = EpisodeStateRecord(
            id: episodeId, showId: showId, positionSeconds: positionSeconds, completed: completed, updatedAt: updatedAt,
            deviceId: stateRecord?.deviceId,
            lastLocalPositionSeconds: positionSeconds, lastLocalPlaybackAt: updatedAt)
        // Keep Subscriptions/Library's cached badges in sync with this write rather than waiting
        // for the next full refresh (#556).
        CatalogCache.recordEpisodeStateChange(
            episodeId: episodeId, showId: showId, completed: completed, positionSeconds: positionSeconds,
            in: modelContext)

        // persist() is only ever reached via a manual write path in *this view* (the completed
        // toggle, or the onDidFinishPlaying callback for a natural finish) — it's never called
        // from the sync-pull path that applies server changes (EpisodeSyncAdapter.apply, which
        // does set autoPlayed = true when the enforcement job marks an episode played elsewhere).
        // So every completion reaching here already satisfies #179's "exclude auto-played
        // episodes" requirement by construction, without needing to check the flag directly —
        // just not for the reason "autoPlayed is only ever set by restoreAutoPlayed()", which
        // isn't true.
        // #179: frees offline storage once an episode is finished, mirroring the auto-played
        // enforcement job's completion hook. Shared with ShowDetailView's swipe-to-mark-played
        // (#532) so both paths apply the same auto-delete-after-played rule.
        if DownloadCleanup.deleteIfAutoDeleteEligible(
            episodeId: episodeId, completed: completed, autoDeleteRule: autoDeleteRule, in: modelContext
        ) {
            downloadStatus = nil
        }
    }

    // Per-show override wins over the global default, matching autoSkipIntroSeconds/
    // autoSkipOutroSeconds/playbackSpeed/smartSpeed's resolution in loadPlaybackSettings().
    nonisolated static func resolvedAutoDeleteRule(show: ShowSettings?, user: UserSettings?) -> AutoDeleteRule {
        show?.autoDeleteRule ?? user?.autoDeleteRule ?? .never
    }
}

// Shared chrome for the episode control row's compact buttons: an equal-width, ~40pt-tall
// neutral raised square. `isActive` swaps in the lime-soft fill + lime hairline for buttons
// that are in a live/enabled state (non-default speed, running sleep timer, marked played).
// Shared with NowPlayingView's quick controls row (#648) — same compact pill/icon-button chrome
// on both screens.
struct EpisodeControlChrome: ViewModifier {
    var isActive = false

    func body(content: Content) -> some View {
        content
            // 44pt keeps every cell at the HIG minimum tap target even though the glyphs are small.
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
            .background(isActive ? KuullaColor.signalSoft : KuullaColor.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.sm)
                    .stroke(isActive ? KuullaColor.signal : KuullaColor.line, lineWidth: 0.5)
            )
    }
}

private struct EpisodeArtworkImage: View {
    let urlString: String?

    var body: some View {
        AsyncImage(url: urlString.flatMap(URL.init)) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            Color.secondary.opacity(0.2)
        }
        // Square frame + clip must live here (before any caller-applied .frame): clipping at the
        // AsyncImage's natural size and letting the caller size it afterwards leaves tall source
        // art overflowing a nominally square slot (#519).
        .frame(width: 96, height: 96)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

#Preview {
    NavigationStack {
        EpisodeDetailView(showId: "preview-show", episodeId: "preview-episode")
    }
    .modelContainer(for: EpisodeStateRecord.self, inMemory: true)
}
