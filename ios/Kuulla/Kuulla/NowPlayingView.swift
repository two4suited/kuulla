import SwiftUI

// The dedicated full-screen player (#646), replacing the mini bar's previous behavior of routing
// to EpisodeDetailView. Scope here is player chrome only — artwork, title, scrubber, transport —
// the inline up-next list, chapter markers, and quick-access controls are follow-up issues (#647,
// #648, #649) that build on top of this screen.
@MainActor
struct NowPlayingView: View {
    // Presented as a sheet from ContentView; called on the close button tap (swipe-to-dismiss is
    // handled natively by the sheet itself).
    let onDismiss: () -> Void

    @State private var audioPlayer = AudioPlayer.shared

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

                Spacer(minLength: 0)
            }
            .padding(Space.lg)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(KuullaColor.background)
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
}

#Preview {
    NowPlayingView(onDismiss: {})
}
