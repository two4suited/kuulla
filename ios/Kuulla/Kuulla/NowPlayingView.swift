import SwiftData
import SwiftUI

// The dedicated full-screen player (#646), replacing the mini bar's previous behavior of routing
// to EpisodeDetailView. Player chrome (artwork, title, scrubber, transport) plus the inline
// up-next queue (#647); chapter markers and quick-access controls are follow-up issues (#648,
// #649) that build on top of this screen.
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

    private let catalogClient = PodcastCatalogClient()

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

    var body: some View {
        if let metadata = audioPlayer.nowPlayingMetadata {
            VStack(spacing: Space.xl) {
                closeButton

                Spacer(minLength: 0)

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

                scrubber

                transportControls

                if playbackQueue.source != nil {
                    upNextList
                } else {
                    // No armed session (e.g. a deep-linked single episode) — hide the queue
                    // entirely rather than showing an empty state (#647).
                    Spacer(minLength: 0)
                }
            }
            .padding(Space.lg)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(KuullaColor.background)
            .task(id: playbackQueue.sessionItems) {
                await loadEpisodeMetadata()
            }
            .task(id: playbackQueue.currentEpisodeId) {
                nextEpisodeId = await playbackQueue.resolvedNextItem()?.episodeId
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

    // The current session's ordered snapshot, rendered in full (#647) — not just the remainder
    // after the current episode, so already-played rows stay visible rather than disappearing.
    // Scrolls independently of the fixed player chrome above it.
    private var upNextList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(playbackQueue.sessionItems, id: \.episodeId) { item in
                    queueRow(item)
                    if item.episodeId != playbackQueue.sessionItems.last?.episodeId {
                        Divider()
                    }
                }
            }
        }
        // Without this, the ScrollView sizes to its content inside the enclosing VStack instead
        // of filling the space the old trailing Spacer(minLength: 0) used to claim — a long queue
        // would overflow past the screen edge instead of scrolling in place.
        .frame(maxHeight: .infinity)
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
}

#Preview {
    NowPlayingView(onDismiss: {})
}
