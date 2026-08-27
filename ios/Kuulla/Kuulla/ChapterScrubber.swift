import SwiftUI

// Renders the playback position slider with a tick mark for each chapter's start time, plus a
// tappable list of chapters below it. Kept as one view (rather than splitting the slider and
// list) since both need the same currentTime/duration/chapters inputs and "seek" action.
struct ChapterScrubber: View {
    let currentTime: TimeInterval
    let duration: TimeInterval
    let chapters: [EpisodeChapter]
    let onSeek: (TimeInterval) -> Void
    // Called instead of onSeek when the tapped row is the currently-active chapter and it has a
    // URL — seeking to the chapter you're already in would just rewind playback back to its start
    // rather than doing anything useful, so that tap is repurposed to open its link (e.g. a
    // sponsor/reference URL) instead. Defaults to a no-op for callers (like previews/tests) that
    // don't care about link handling.
    var onOpenLink: (URL) -> Void = { _ in }

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
                            .frame(width: ChapterScrubber.tickWidth, height: 8)
                            .offset(x: ChapterScrubber.tickOffset(
                                startTime: chapter.startTime, duration: effectiveDuration, trackWidth: geometry.size.width))
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
                    if editing {
                        // Without this, dragValue still holds whatever it was left at by the
                        // previous drag (or 0, before any drag has happened) — the thumb would
                        // visibly jump there the instant isDragging flips true, before the first
                        // drag delta arrives to correct it.
                        dragValue = min(max(currentTime, 0), effectiveDuration)
                    }
                    isDragging = editing
                    if !editing {
                        onSeek(dragValue)
                    }
                }
            )
            .accessibilityLabel("Playback position")
            .accessibilityValue(EpisodeFormatting.formatDuration(displayedTime))

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
                        // Computed once and reused below (rather than calling tapAction(for:) a
                        // second time for .accessibilityHint) — it re-parses the chapter's URL,
                        // which would otherwise repeat on every render while playback updates.
                        let tapAction = ChapterScrubber.tapAction(for: chapter, isActive: index == activeChapterIndex)
                        Button {
                            switch tapAction {
                            case .openLink(let url):
                                onOpenLink(url)
                            case .seek(let startTime):
                                onSeek(startTime)
                            }
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
                        // The tap action switches between seeking and opening a link depending on
                        // whether this row is active + has a URL — VoiceOver only reads the title
                        // and time otherwise, with no way to tell which action activating it will
                        // take.
                        .accessibilityHint(tapAction.accessibilityHint)
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
        // The index of the greatest startTime <= currentTime, found by comparison rather than
        // taking the last matching index — the backend preserves the feed's own chapter JSON
        // order, which isn't guaranteed to be sorted by startTime, so `.last` would pick the
        // wrong chapter for an out-of-order feed.
        chapters.indices
            .filter { chapters[$0].startTime <= currentTime }
            .max { chapters[$0].startTime < chapters[$1].startTime }
    }

    static let tickWidth: CGFloat = 2

    // Pulled out as a pure static function (mirroring activeChapterIndex above) so the tick's
    // placement math is unit-testable without a real GeometryReader. Clamped to
    // [0, trackWidth - tickWidth] rather than the raw fraction * trackWidth — an end-of-episode
    // chapter (startTime == duration) would otherwise land its tick exactly at the track's
    // trailing edge, rendering it fully off-screen, and a chapter with a startTime past duration
    // (bad data, or duration temporarily 0) could push the offset arbitrarily far beyond the
    // track altogether.
    static func tickOffset(startTime: TimeInterval, duration: TimeInterval, trackWidth: CGFloat) -> CGFloat {
        let rawOffset = trackWidth * CGFloat(startTime / duration)
        // The upper bound itself is clamped to >= 0 — trackWidth can be 0 (or smaller than
        // tickWidth) during initial layout/transitions, which would otherwise make
        // `trackWidth - tickWidth` negative and let a negative offset through.
        let maxOffset = max(trackWidth - tickWidth, 0)
        return min(max(rawOffset, 0), maxOffset)
    }

    enum TapAction: Equatable {
        case seek(TimeInterval)
        case openLink(URL)

        var accessibilityHint: String {
            switch self {
            case .seek: "Seeks to this chapter."
            case .openLink: "Opens this chapter's link."
            }
        }
    }

    // Pulled out as a pure static function (mirroring activeChapterIndex above) so the
    // seek-vs-open-link decision is unit-testable without going through the SwiftUI Button action.
    // Restricted to http/https — SFSafariViewController is built for web content, and a
    // scheme-less or non-web URL (a chapter's url happens to be "sponsor" or a custom scheme)
    // would just present a sheet that fails to load rather than doing anything useful.
    static func tapAction(for chapter: EpisodeChapter, isActive: Bool) -> TapAction {
        if isActive, let urlString = chapter.url, let url = URL(string: urlString),
           let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            return .openLink(url)
        }
        return .seek(chapter.startTime)
    }
}
