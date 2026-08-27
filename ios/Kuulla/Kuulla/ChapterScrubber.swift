import SwiftUI

// Renders the playback position slider with a tick mark for each chapter's start time, plus a
// tappable list of chapters below it. Kept as one view (rather than splitting the slider and
// list) since both need the same currentTime/duration/chapters inputs and "seek" action.
struct ChapterScrubber: View {
    let currentTime: TimeInterval
    let duration: TimeInterval
    let chapters: [EpisodeChapter]
    let onSeek: (TimeInterval) -> Void

    // Local drag state so the slider tracks the user's finger smoothly and only actually seeks
    // once they lift it — seeking on every intermediate value would flood AVPlayer with seeks and
    // make the thumb visibly stutter against the periodic time observer's own updates.
    @State private var isDragging = false
    @State private var dragValue: TimeInterval = 0

    // Slider's range can't be empty/zero-width — a duration of 0 (not yet resolved by the
    // periodic time observer) would otherwise crash the Slider's `in:` range.
    private var effectiveDuration: TimeInterval { max(duration, 1) }
    private var displayedTime: TimeInterval { isDragging ? dragValue : currentTime }

    private var activeChapterIndex: Int? {
        ChapterScrubber.activeChapterIndex(chapters: chapters, currentTime: displayedTime)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    ForEach(Array(chapters.enumerated()), id: \.offset) { _, chapter in
                        Rectangle()
                            .fill(.secondary)
                            .frame(width: 2, height: 8)
                            .offset(x: geometry.size.width * CGFloat(chapter.startTime / effectiveDuration))
                    }
                }
            }
            .frame(height: 8)

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
                    isDragging = editing
                    if !editing {
                        onSeek(dragValue)
                    }
                }
            )

            HStack {
                Text(EpisodeFormatting.formatDuration(displayedTime))
                Spacer()
                Text(EpisodeFormatting.formatDuration(duration))
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if !chapters.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(chapters.enumerated()), id: \.offset) { index, chapter in
                        Button {
                            onSeek(chapter.startTime)
                        } label: {
                            HStack {
                                Text(chapter.title)
                                Spacer()
                                Text(EpisodeFormatting.formatDuration(chapter.startTime))
                                    .foregroundStyle(.secondary)
                            }
                            .font(index == activeChapterIndex ? .subheadline.bold() : .subheadline)
                            .foregroundStyle(index == activeChapterIndex ? Color.accentColor : .primary)
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    // The last chapter whose startTime has already been reached — pulled out as a pure static
    // function so the "which chapter is currently playing" logic is unit-testable without a real
    // Slider/GeometryReader.
    static func activeChapterIndex(chapters: [EpisodeChapter], currentTime: TimeInterval) -> Int? {
        chapters.indices.last { chapters[$0].startTime <= currentTime }
    }
}
