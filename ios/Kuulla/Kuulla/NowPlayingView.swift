import SwiftData
import SwiftUI

// The dedicated full-screen player (#646), replacing the mini bar's previous behavior of routing
// to EpisodeDetailView. Player chrome (artwork, title, scrubber, transport), the inline up-next
// queue (#647), chapter markers (#649), and playback speed / sleep timer quick controls (#648).
@MainActor
struct NowPlayingView: View {
    // Presented as a sheet from ContentView; called on the close button tap (swipe-to-dismiss is
    // handled natively by the sheet itself).
    let onDismiss: () -> Void

    @State private var audioPlayer = AudioPlayer.shared
    // @Observable, mirroring audioPlayer above — reading its properties in body re-renders this
    // view as the session advances (a natural finish, or a tap on a queue row).
    @State private var playbackQueue = PlaybackQueue.shared
    @Environment(\.modelContext) private var modelContext

    // Episode metadata for the inline queue (#647), resolved cache-first and keyed by episodeId —
    // PlaybackQueue's own snapshot only carries show/episode ids, not titles.
    @State private var resolvedEpisodes: [String: Episode] = [:]
    // The item PlaybackQueue.resolvedNextItem() says will play automatically when the current
    // episode finishes — recomputed whenever currentEpisodeId changes, since it depends on an
    // async settings/playlist fetch rather than being derivable from the snapshot alone.
    @State private var nextEpisodeId: String?

    // Chapter markers on the scrubber (#649). Non-nil while a chapter link (e.g. a sponsor URL)
    // is open in the in-app browser.
    @State private var chapterLinkURL: URL?

    // Quick-access playback speed / sleep timer controls (#648).
    @State private var isShowingSleepTimer = false
    @State private var playbackSpeedSaveTask: Task<Void, Never>?
    @State private var playbackSpeedSaveError: String?
    // Bumped on every playback speed selection — same coalescing pattern as
    // EpisodeDetailView.savePlaybackSpeed, so only the latest value a user settles on is sent.
    @State private var playbackSpeedSaveVersion = 0

    private let catalogClient = PodcastCatalogClient()
    private let settingsClient = SettingsClient()

    // Matches NowPlayingBar's skip intervals — every surface skips by the same amount.
    private static let skipBackInterval: TimeInterval = 15
    private static let skipForwardInterval: TimeInterval = 30

    // Local drag state so the slider tracks the user's finger smoothly and only actually seeks
    // once they lift it, mirroring ChapterScrubber's own drag handling.
    @State private var isDragging = false
    @State private var dragValue: TimeInterval = 0

    // Slider's range can't be empty/zero-width — a duration of 0 (not yet resolved by the
    // periodic time observer) would otherwise crash the Slider's `in:` range.
    private var effectiveDuration: TimeInterval { max(audioPlayer.duration, 1) }
    private var displayedTime: TimeInterval { isDragging ? dragValue : audioPlayer.currentTime }
    private var remainingTime: TimeInterval { max(effectiveDuration - displayedTime, 0) }

    // The currently-playing episode's chapters, if any and if resolved yet — reuses
    // resolvedEpisodes (populated for the queue's rows too) rather than a separate fetch, keyed by
    // AudioPlayer's own nowPlayingContext since a deep-linked episode has no PlaybackQueue session
    // to source it from.
    private var currentEpisodeChapters: [EpisodeChapter] {
        guard let episodeId = audioPlayer.nowPlayingContext?.episodeId else { return [] }
        return resolvedEpisodes[episodeId]?.chapters ?? []
    }

    var body: some View {
        if let metadata = audioPlayer.nowPlayingMetadata {
            VStack(spacing: 0) {
                closeButton

                // A single ScrollView for everything below the close button — the up-next queue
                // (#647) and, for a chapter-heavy episode, ChapterScrubber's own chapter list
                // (#649) are both unbounded in length, so the chrome above them can't be fixed
                // height without risking either one overflowing the screen.
                ScrollView {
                    VStack(spacing: Space.xl) {
                        artwork(metadata)

                        VStack(spacing: Space.xs) {
                            Text(metadata.title)
                                .font(.kuullaTitle(20, relativeTo: .title2))
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                            if let showTitle = metadata.showTitle {
                                Text(showTitle)
                                    .font(.kuullaBody(15))
                                    .foregroundStyle(KuullaColor.textMuted)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.horizontal, Space.lg)

                        if currentEpisodeChapters.isEmpty {
                            scrubber
                        } else {
                            ChapterScrubber(
                                currentTime: displayedTime, duration: effectiveDuration,
                                chapters: currentEpisodeChapters,
                                onSeek: { audioPlayer.seek(to: $0) },
                                onOpenLink: { chapterLinkURL = $0 })
                        }

                        transportControls

                        quickControls

                        if playbackQueue.source != nil {
                            upNextSection
                        }
                    }
                    .padding(Space.lg)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(KuullaColor.background)
            .task(id: playbackQueue.sessionItems) {
                await loadEpisodeMetadata()
            }
            .task(id: playbackQueue.currentEpisodeId) {
                nextEpisodeId = await playbackQueue.resolvedNextItem()?.episodeId
            }
            .task(id: audioPlayer.nowPlayingContext?.episodeId) {
                await loadCurrentEpisodeMetadataIfNeeded()
            }
            .sheet(isPresented: Binding(get: { chapterLinkURL != nil }, set: { if !$0 { chapterLinkURL = nil } })) {
                if let chapterLinkURL {
                    // .id forces a fresh SFSafariViewController when the URL changes — its URL
                    // can't be updated after init, mirroring EpisodeDetailView's own chapter link
                    // sheet.
                    SafariView(url: chapterLinkURL)
                        .id(chapterLinkURL)
                }
            }
        } else {
            // Nothing loaded (e.g. the session ended while this screen was still open) — dismiss
            // rather than show an empty player with no way back other than the close button.
            Color.clear.onAppear(perform: onDismiss)
        }
    }

    private var closeButton: some View {
        HStack {
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(KuullaColor.textPrimary)
            }
            .accessibilityLabel("Close")
        }
        // Now that the rest of the content lives in a ScrollView with its own Space.lg padding
        // (see body), the close button — outside that scroll view so it stays fixed — needs the
        // same padding applied directly rather than inheriting it from a shared parent.
        .padding([.horizontal, .top], Space.lg)
    }

    private func artwork(_ metadata: NowPlayingMetadata) -> some View {
        AsyncImage(url: metadata.artworkURL) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            ZStack {
                KuullaColor.surfaceRaised
                Image(systemName: "mic").font(.system(size: 48)).foregroundStyle(.secondary)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 320)
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
    }

    private var scrubber: some View {
        VStack(spacing: Space.xs) {
            Slider(
                value: Binding(
                    // Clamped rather than passed straight through — AudioPlayer can report
                    // currentTime > 0 before duration is populated by the periodic time observer
                    // (duration defaults to 0, so effectiveDuration is briefly 1), and an
                    // unclamped value outside 0...effectiveDuration triggers a SwiftUI runtime
                    // warning and a visibly stuck/invalid thumb position.
                    get: { min(max(displayedTime, 0), effectiveDuration) },
                    set: { dragValue = $0 }
                ),
                in: 0...effectiveDuration,
                onEditingChanged: { editing in
                    if editing {
                        // Without this, dragValue still holds whatever it was left at by the
                        // previous drag (or 0) — the thumb would visibly jump there the instant
                        // isDragging flips true, before the first drag delta arrives to correct it.
                        dragValue = min(max(audioPlayer.currentTime, 0), effectiveDuration)
                    }
                    isDragging = editing
                    if !editing {
                        audioPlayer.seek(to: dragValue)
                    }
                }
            )
            .tint(KuullaColor.signal)
            .accessibilityLabel("Playback position")
            .accessibilityValue(EpisodeFormatting.formatDuration(displayedTime))

            HStack {
                Text(EpisodeFormatting.formatDuration(displayedTime))
                Spacer()
                Text("-\(EpisodeFormatting.formatDuration(remainingTime))")
            }
            .font(.kuullaMono(12))
            .foregroundStyle(KuullaColor.textMuted)
        }
    }

    private var transportControls: some View {
        HStack(spacing: Space.xxl) {
            Button {
                audioPlayer.handleSkipBackwardCommand(interval: Self.skipBackInterval)
            } label: {
                Image(systemName: "gobackward.15").font(.system(size: 32))
            }
            .foregroundStyle(KuullaColor.textPrimary)
            .accessibilityLabel("Skip back 15 seconds")

            Button {
                audioPlayer.isPlaying ? audioPlayer.pause() : audioPlayer.resume()
            } label: {
                Image(systemName: audioPlayer.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 48))
                    .frame(width: 56)
            }
            // Play is the one primary action, so it carries the signal accent (docs/brand.md §9).
            .foregroundStyle(KuullaColor.signal)
            .accessibilityLabel(audioPlayer.isPlaying ? "Pause" : "Play")

            Button {
                audioPlayer.handleSkipForwardCommand(interval: Self.skipForwardInterval)
            } label: {
                Image(systemName: "goforward.30").font(.system(size: 32))
            }
            .foregroundStyle(KuullaColor.textPrimary)
            .accessibilityLabel("Skip forward 30 seconds")
        }
        .buttonStyle(.plain)
    }

    // A value pill (speed) and an icon button (sleep timer) — compact supplementary chrome, not a
    // settings page (#648). Unlike EpisodeDetailView's own copy of these controls, this screen only
    // ever shows while something is actually loaded in AudioPlayer, so there's no need for that
    // view's "is this screen's episode the one actually playing" guard before applying a live
    // rate change — audioPlayer.playbackSpeed already reflects what's playing right now.
    private var quickControls: some View {
        VStack(spacing: Space.xs) {
            HStack(spacing: Space.sm) {
                Menu {
                    ForEach(Self.sortedPlaybackSpeedOptions) { option in
                        Button {
                            selectPlaybackSpeed(option)
                        } label: {
                            if option.rawValue == audioPlayer.playbackSpeed {
                                Label(option.label, systemImage: "checkmark")
                            } else {
                                Text(option.label)
                            }
                        }
                    }
                } label: {
                    Text(playbackSpeedLabel)
                        .font(.kuullaMono(13))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(audioPlayer.playbackSpeed == 1.0 ? KuullaColor.textMuted : KuullaColor.signalInk)
                }
                .modifier(EpisodeControlChrome(isActive: audioPlayer.playbackSpeed != 1.0))
                .accessibilityLabel("Playback speed, \(playbackSpeedLabel)")

                Button {
                    isShowingSleepTimer = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: sleepTimerActive ? "moon.zzz.fill" : "moon.zzz")
                            .font(.system(size: 15))
                        if let remaining = SleepTimerSheet.formatRemaining(audioPlayer.sleepTimerRemainingSeconds) {
                            Text(remaining)
                                .font(.kuullaMono(13))
                        } else if audioPlayer.sleepTimerEndOfEpisodeEnabled {
                            Text("EOE")
                                .font(.kuullaMono(13))
                        }
                    }
                    .foregroundStyle(sleepTimerActive ? KuullaColor.signalInk : KuullaColor.textMuted)
                }
                .buttonStyle(.plain)
                .modifier(EpisodeControlChrome(isActive: sleepTimerActive))
                .accessibilityLabel(sleepTimerButtonTitle)
            }

            if let playbackSpeedSaveError {
                Text(playbackSpeedSaveError)
                    .font(.caption)
                    .foregroundStyle(KuullaColor.danger)
            }
        }
        .sheet(isPresented: $isShowingSleepTimer) {
            SleepTimerSheet()
        }
    }

    private var playbackSpeedLabel: String {
        if let option = PlaybackSpeedOption(rawValue: audioPlayer.playbackSpeed) {
            return option.label
        }
        return "\(audioPlayer.playbackSpeed.formatted(.number.precision(.fractionLength(0...2))))x"
    }

    private var sleepTimerActive: Bool {
        audioPlayer.sleepTimerEndOfEpisodeEnabled || audioPlayer.sleepTimerRemainingSeconds != nil
    }

    private var sleepTimerButtonTitle: String {
        if audioPlayer.sleepTimerEndOfEpisodeEnabled {
            return "Sleep Timer: End of Episode"
        }
        if let remaining = SleepTimerSheet.formatRemaining(audioPlayer.sleepTimerRemainingSeconds) {
            return "Sleep Timer: \(remaining)"
        }
        return "Sleep Timer"
    }

    private static let sortedPlaybackSpeedOptions = PlaybackSpeedOption.allCases.sorted { $0.rawValue < $1.rawValue }

    // Applies the picked speed live and persists it, mirroring EpisodeDetailView.selectPlaybackSpeed.
    private func selectPlaybackSpeed(_ option: PlaybackSpeedOption) {
        audioPlayer.setPlaybackSpeed(option.rawValue)
        savePlaybackSpeed(option.rawValue)
    }

    // Chains each save behind the previous one, same rationale as
    // EpisodeDetailView.savePlaybackSpeed — the endpoint is a plain read-then-upsert, so
    // overlapping in-flight PUTs could otherwise land out of order and persist a stale speed.
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

    // The current session's ordered snapshot, rendered in full (#647) — not just the remainder
    // after the current episode, so already-played rows stay visible rather than disappearing.
    // Part of the screen's single outer ScrollView (see body) rather than scrolling on its own, so
    // it shares scroll space with a chapter-heavy episode's own chapter list instead of each
    // claiming a separately-scrolling region.
    private var upNextSection: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Divider()
            ForEach(playbackQueue.sessionItems, id: \.episodeId) { item in
                queueRow(item)
                if item.episodeId != playbackQueue.sessionItems.last?.episodeId {
                    Divider()
                }
            }
        }
    }

    private func queueRow(_ item: PlaybackQueue.QueueItem) -> some View {
        let isCurrent = item.episodeId == playbackQueue.currentEpisodeId
        let isNext = !isCurrent && item.episodeId == nextEpisodeId
        let isConsumed = playbackQueue.consumedEpisodeIds.contains(item.episodeId)
        let episode = resolvedEpisodes[item.episodeId]

        return Button {
            Task { await playbackQueue.playUpNextItem(item) }
        } label: {
            HStack(spacing: Space.sm) {
                Image(systemName: isCurrent ? "speaker.wave.2.fill" : (isConsumed ? "checkmark.circle.fill" : "circle"))
                    .font(.system(size: 13))
                    .foregroundStyle(isCurrent ? KuullaColor.signal : KuullaColor.textMuted)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(episode?.title ?? "Episode unavailable")
                        .font(.kuullaBody(15, weight: isCurrent || isNext ? .semibold : .regular))
                        .foregroundStyle(isConsumed && !isCurrent ? KuullaColor.textMuted : KuullaColor.textPrimary)
                        .lineLimit(2)
                    if isCurrent {
                        Text("Now playing")
                            .font(.kuullaMono(11))
                            .foregroundStyle(KuullaColor.textMuted)
                    } else if isNext {
                        Text("Plays next")
                            .font(.kuullaMono(11))
                            .foregroundStyle(KuullaColor.signal)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.vertical, Space.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Tapping the current row would just re-jump to itself — still visible, just inert.
        .disabled(isCurrent)
        .accessibilityLabel(episode?.title ?? "Episode unavailable")
        .accessibilityHint(isCurrent ? "Now playing" : "Play this episode")
    }

    // Resolves titles cache-first via CatalogCache, falling back to the network concurrently for
    // anything not cached — mirrors CarPlaySceneDelegate.pushUpNextList's resolution for the same
    // PlaybackQueue snapshot.
    private func loadEpisodeMetadata() async {
        let items = playbackQueue.sessionItems
        guard !items.isEmpty else { return }

        var episodes = resolvedEpisodes
        await withTaskGroup(of: (String, Episode?).self) { group in
            for item in items where episodes[item.episodeId] == nil {
                if let cached = CatalogCache.episode(showId: item.showId, episodeId: item.episodeId, in: modelContext) {
                    episodes[item.episodeId] = cached
                    continue
                }
                let showId = item.showId
                let episodeId = item.episodeId
                group.addTask { [catalogClient] in
                    (episodeId, try? await catalogClient.getEpisode(showId: showId, episodeId: episodeId))
                }
            }
            for await (episodeId, episode) in group {
                if let episode { episodes[episodeId] = episode }
            }
        }
        resolvedEpisodes = episodes
    }

    // Resolves the currently-playing episode into resolvedEpisodes for its chapters (#649) —
    // separate from loadEpisodeMetadata above because a deep-linked episode (no PlaybackQueue
    // session) never appears in sessionItems at all, but still needs its chapters resolved for the
    // scrubber. A no-op whenever the episode is already resolved, which is the common case once
    // loadEpisodeMetadata has already fetched it as part of the session's own queue.
    private func loadCurrentEpisodeMetadataIfNeeded() async {
        guard let context = audioPlayer.nowPlayingContext, resolvedEpisodes[context.episodeId] == nil else { return }
        if let cached = CatalogCache.episode(showId: context.showId, episodeId: context.episodeId, in: modelContext) {
            resolvedEpisodes[context.episodeId] = cached
            return
        }
        if let episode = try? await catalogClient.getEpisode(showId: context.showId, episodeId: context.episodeId) {
            resolvedEpisodes[context.episodeId] = episode
        }
    }
}

#Preview {
    NowPlayingView(onDismiss: {})
}
