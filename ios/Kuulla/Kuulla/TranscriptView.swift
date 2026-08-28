import SwiftUI

// A scrollable transcript pane for the player screen: timed segments that highlight and
// auto-scroll to keep pace with playback, and seek when tapped. Given its own fixed-height
// scroll area (rather than laid out inline) so a long transcript stays navigable and the
// auto-scroll has something to drive.
//
// A search field filters the list to matching lines, highlights the query within them, and
// (via the up/down controls) steps playback through each occurrence.
struct TranscriptView: View {
    let segments: [TranscriptSegment]
    let currentTime: TimeInterval
    let onSeek: (TimeInterval) -> Void

    @State private var query = ""
    // Which match, 0-based, the next/previous controls currently point at. Reset whenever the
    // query changes.
    @State private var selectedMatchOrdinal = 0

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isSearching: Bool { !trimmedQuery.isEmpty }

    // Indices into `segments`, in document order, whose text contains the query.
    private var matchIndices: [Int] {
        TranscriptSearch.matchIndices(segments: segments, query: query)
    }

    // Playback-position highlight only applies when not searching — during a search the list is
    // filtered and the user is navigating matches, not following the playhead.
    private var activePlaybackIndex: Int? {
        isSearching ? nil : TranscriptSync.activeSegmentIndex(segments: segments, currentTime: currentTime)
    }

    private var selectedMatchIndex: Int? {
        guard isSearching, !matchIndices.isEmpty else { return nil }
        return matchIndices[clampedOrdinal]
    }

    private var clampedOrdinal: Int {
        guard !matchIndices.isEmpty else { return 0 }
        return min(max(selectedMatchOrdinal, 0), matchIndices.count - 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            searchField

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if isSearching {
                            if matchIndices.isEmpty {
                                Text("No matching lines.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .padding(.vertical, 8)
                            }
                            // matchIndices is an array either way (a filter result); everything
                            // else iterates segments.indices directly to avoid allocating a copy
                            // on every body pass while playback ticks.
                            ForEach(matchIndices, id: \.self) { segmentRow($0) }
                        } else {
                            ForEach(segments.indices, id: \.self) { segmentRow($0) }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(height: 320)
                .onChange(of: activePlaybackIndex) { _, newIndex in
                    guard let newIndex else { return }
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(newIndex, anchor: .center)
                    }
                }
                .onChange(of: selectedMatchIndex) { _, newIndex in
                    guard let newIndex else { return }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(newIndex, anchor: .center)
                    }
                }
                .onChange(of: query) { _, _ in
                    selectedMatchOrdinal = 0
                }
                .onAppear {
                    if let activePlaybackIndex {
                        proxy.scrollTo(activePlaybackIndex, anchor: .center)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func segmentRow(_ index: Int) -> some View {
        Button {
            onSeek(segments[index].startTime)
        } label: {
            TranscriptRow(
                text: segments[index].text,
                // Only non-nil while searching, so the non-search path never builds an
                // AttributedString (this view re-renders on every playback tick).
                highlight: isSearching ? trimmedQuery : nil,
                startTime: segments[index].startTime,
                isActive: index == activePlaybackIndex || index == selectedMatchIndex)
        }
        .buttonStyle(.plain)
        .id(index)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Transcript")
                .font(.kuullaTitle(17, relativeTo: .headline))

            if isSearching {
                Spacer()

                if matchIndices.isEmpty {
                    Text("No matches")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(clampedOrdinal + 1) of \(matchIndices.count)")
                        .font(.kuullaMono(12))
                        .foregroundStyle(KuullaColor.textMuted)

                    Button { step(by: -1) } label: {
                        Image(systemName: "chevron.up")
                    }
                    .accessibilityLabel("Previous match")

                    Button { step(by: 1) } label: {
                        Image(systemName: "chevron.down")
                    }
                    .accessibilityLabel("Next match")
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search transcript", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(8)
        .background(KuullaColor.surfaceRaised, in: RoundedRectangle(cornerRadius: Radius.sm))
    }

    // Advances the selected match by ±1 (wrapping), scrolls it into view (via onChange above) and
    // seeks playback to it — so the up/down controls step audibly through every occurrence.
    private func step(by delta: Int) {
        let count = matchIndices.count
        guard count > 0 else { return }
        selectedMatchOrdinal = ((clampedOrdinal + delta) % count + count) % count
        if let index = selectedMatchIndex {
            onSeek(segments[index].startTime)
        }
    }

}

private struct TranscriptRow: View {
    let text: String
    // The trimmed search query when searching, nil otherwise. Only when non-nil is an
    // AttributedString built to mark the matches.
    let highlight: String?
    let startTime: TimeInterval
    let isActive: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(EpisodeFormatting.formatDuration(startTime))
                .font(.kuullaMono(12))
                .foregroundStyle(KuullaColor.textMuted)
                .frame(minWidth: 44, alignment: .leading)

            lineText
                .font(.kuullaBody(15, weight: isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? KuullaColor.signalInk : KuullaColor.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Seeks to this point in the episode.")
    }

    private var lineText: Text {
        if let highlight, !highlight.isEmpty {
            return Text(Self.highlighted(text, query: highlight))
        }
        return Text(text)
    }

    private static func highlighted(_ text: String, query: String) -> AttributedString {
        var attributed = AttributedString(text)
        var searchStart = attributed.startIndex
        while searchStart < attributed.endIndex,
              let range = attributed[searchStart...].range(of: query, options: TranscriptSearch.options) {
            attributed[range].backgroundColor = KuullaColor.signalSoft
            attributed[range].inlinePresentationIntent = .stronglyEmphasized
            searchStart = range.upperBound
        }
        return attributed
    }
}
