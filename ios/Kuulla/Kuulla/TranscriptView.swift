import SwiftUI

// A scrollable transcript pane for the player screen: timed segments that highlight and
// auto-scroll to keep pace with playback, and seek when tapped. Given its own fixed-height
// scroll area (rather than laid out inline) so a long transcript stays navigable and the
// auto-scroll has something to drive.
struct TranscriptView: View {
    let segments: [TranscriptSegment]
    let currentTime: TimeInterval
    let onSeek: (TimeInterval) -> Void

    private var activeIndex: Int? {
        TranscriptSync.activeSegmentIndex(segments: segments, currentTime: currentTime)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Transcript")
                .font(.headline)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                            Button {
                                onSeek(segment.startTime)
                            } label: {
                                TranscriptRow(segment: segment, isActive: index == activeIndex)
                            }
                            .buttonStyle(.plain)
                            .id(index)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(height: 320)
                .onChange(of: activeIndex) { _, newIndex in
                    guard let newIndex else { return }
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(newIndex, anchor: .center)
                    }
                }
                .onAppear {
                    // Jump straight to wherever playback already is when the pane first appears,
                    // without the animation onChange uses for in-flight updates.
                    if let activeIndex {
                        proxy.scrollTo(activeIndex, anchor: .center)
                    }
                }
            }
        }
    }
}

private struct TranscriptRow: View {
    let segment: TranscriptSegment
    let isActive: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(EpisodeFormatting.formatDuration(segment.startTime))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, alignment: .leading)

            Text(segment.text)
                .font(isActive ? .body.weight(.semibold) : .body)
                .foregroundStyle(isActive ? Color.accentColor : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Seeks to this point in the episode.")
    }
}
