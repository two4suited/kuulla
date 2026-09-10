import SwiftUI

// A compact, always-visible playback bar pinned above the tab bar (#542). It observes
// AudioPlayer.shared, so it reflects whatever is loaded — including a playlist auto-advance
// (#541) to the next episode — without any EpisodeDetailView being on screen. Renders nothing
// until the first play() of the session gives AudioPlayer a context to show.
@MainActor
struct NowPlayingBar: View {
    // Tapping the bar hands the loaded episode's route back to ContentView, which pushes it onto
    // the active tab's own navigation stack (the bar has no NavigationPath of its own).
    let onOpen: (CatalogRoute) -> Void

    @State private var audioPlayer = AudioPlayer.shared

    // 15s back / 30s forward — matches AudioPlayer's MPRemoteCommandCenter preferredIntervals and
    // the lock screen / CarPlay transport, so every surface skips by the same amount.
    private static let skipBackInterval: TimeInterval = 15
    private static let skipForwardInterval: TimeInterval = 30

    // The EpisodeDetailView route for whatever is loaded — .playlistEpisode when the session was
    // started from a manual playlist, so reopening it from the bar keeps auto-advance (#532)
    // armed; a plain .episode otherwise. Pulled out as a pure function for unit testing, mirroring
    // the codebase's other decision-logic seams.
    nonisolated static func route(for context: NowPlayingContext) -> CatalogRoute {
        if let playlistId = context.playlistId {
            return .playlistEpisode(playlistId: playlistId, showId: context.showId, episodeId: context.episodeId)
        }
        return .episode(showId: context.showId, episodeId: context.episodeId)
    }

    private var progress: Double {
        guard audioPlayer.duration > 0 else { return 0 }
        return min(1, max(0, audioPlayer.currentTime / audioPlayer.duration))
    }

    var body: some View {
        if let context = audioPlayer.nowPlayingContext, let metadata = audioPlayer.nowPlayingMetadata {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: Space.md) {
                    Button {
                        onOpen(Self.route(for: context))
                    } label: {
                        episodeLabel(metadata)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Now playing: \(metadata.title)")
                    .accessibilityHint("Opens the episode")

                    transportControls
                }
                .padding(.horizontal, Space.lg)
                .padding(.vertical, Space.sm)
                .overlay(alignment: .top) { progressBar }
            }
            .background(KuullaColor.surface)
        }
    }

    private func episodeLabel(_ metadata: NowPlayingMetadata) -> some View {
        HStack(spacing: Space.md) {
            AsyncImage(url: metadata.artworkURL) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                ZStack {
                    Color.secondary.opacity(0.2)
                    Image(systemName: "mic").foregroundStyle(.secondary)
                }
            }
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                Text(metadata.title)
                    .font(.kuullaBody(14))
                    .foregroundStyle(KuullaColor.textPrimary)
                    .lineLimit(1)
                if let showTitle = metadata.showTitle {
                    Text(showTitle)
                        .font(.kuullaBody(12))
                        .foregroundStyle(KuullaColor.textMuted)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private var transportControls: some View {
        HStack(spacing: Space.lg) {
            Button {
                audioPlayer.handleSkipBackwardCommand(interval: Self.skipBackInterval)
            } label: {
                Image(systemName: "gobackward.15").font(.system(size: 20))
            }
            .foregroundStyle(KuullaColor.textPrimary)
            .accessibilityLabel("Skip back 15 seconds")

            Button {
                audioPlayer.isPlaying ? audioPlayer.pause() : audioPlayer.resume()
            } label: {
                Image(systemName: audioPlayer.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 24))
                    .frame(width: 28)
            }
            // Play is the one primary action, so it carries the signal accent (docs/brand.md §9).
            .foregroundStyle(KuullaColor.signal)
            .accessibilityLabel(audioPlayer.isPlaying ? "Pause" : "Play")

            Button {
                audioPlayer.handleSkipForwardCommand(interval: Self.skipForwardInterval)
            } label: {
                Image(systemName: "goforward.30").font(.system(size: 20))
            }
            .foregroundStyle(KuullaColor.textPrimary)
            .accessibilityLabel("Skip forward 30 seconds")
        }
        .buttonStyle(.plain)
    }

    private var progressBar: some View {
        GeometryReader { geo in
            KuullaColor.signal
                .frame(width: geo.size.width * progress)
        }
        .frame(height: 2)
    }
}
