import SwiftData
import SwiftUI

// Trailing download control shared by FeedView, ShowDetailView, and EpisodeDetailView's episode
// rows: not-downloaded (down-arrow, tap to start), in-progress (circular ring bound to
// DownloadManager's live per-episode progress, tap to cancel), or downloaded (checkmark, tap to
// delete). A `.failed` record is treated the same as "not downloaded" — retrying is just a fresh
// download, not a distinct action a user needs to see represented separately.
struct DownloadButton: View {
    let episode: Episode
    let status: DownloadStatus?
    // Fires once when this episode's tracked download stops being in-flight (completes, fails,
    // or is cancelled) — the parent's `status` is a snapshot from its own last SwiftData fetch,
    // not something that updates itself, so without this callback the button would keep showing
    // the ring (or worse, revert to "not downloaded" and let a tap start a redundant second
    // download of the same episode) until the parent screen happens to reload for some other
    // reason.
    var onDidFinish: (() -> Void)?
    // When true the button stretches to fill its container and hit-tests across the whole area,
    // rather than staying a 22pt glyph. Used by the episode screen's control row, where it sits
    // in an equal-width 44pt cell alongside other icon buttons; the compact episode rows leave
    // it false so the trailing glyph keeps its natural size.
    var fillsContainer = false

    @Environment(\.modelContext) private var modelContext
    @State private var downloadManager = DownloadManager.shared

    private var liveProgress: Double? {
        downloadManager.progress[episode.id]
    }

    private var effectiveStatus: DownloadStatus? {
        Self.effectiveStatus(liveProgress: liveProgress, persistedStatus: status)
    }

    // Pulled out as a pure function for testability. Live progress tracking takes priority over
    // the parent-supplied status: the moment a download starts, DownloadManager's progress
    // dictionary gains an entry before any SwiftData write the parent could have observed, so
    // trusting `persistedStatus` alone here would show a stale down-arrow for the first tick(s)
    // of every download.
    static func effectiveStatus(liveProgress: Double?, persistedStatus: DownloadStatus?) -> DownloadStatus? {
        liveProgress != nil ? .downloading : persistedStatus
    }

    var body: some View {
        Button(action: performAction) {
            icon
                .frame(width: 22, height: 22)
                .frame(maxWidth: fillsContainer ? .infinity : nil, maxHeight: fillsContainer ? .infinity : nil)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue ?? "")
        .onChange(of: liveProgress) { oldValue, newValue in
            if oldValue != nil && newValue == nil {
                onDidFinish?()
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch effectiveStatus {
        case .complete:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .downloading:
            if let liveProgress {
                ZStack {
                    Circle()
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: liveProgress)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
            } else {
                // A persisted .downloading record with no matching entry in
                // DownloadManager.progress means there's no in-flight transfer this launch
                // actually knows about yet (e.g. right after relaunch, before the reconnected
                // background session's first progress callback arrives) — an empty ring at 0%
                // would misleadingly read as "just started" rather than "state unknown".
                ProgressView()
                    .controlSize(.small)
            }
        case .failed, nil:
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(.secondary)
        }
    }

    private var accessibilityLabel: String {
        switch effectiveStatus {
        case .complete: "Delete download"
        case .downloading: "Cancel download"
        case .failed, nil: "Download episode"
        }
    }

    // VoiceOver has no way to see the progress ring's fill, so downloading state needs its
    // completion percentage spelled out explicitly; every other state has nothing to report.
    private var accessibilityValue: String? {
        guard effectiveStatus == .downloading, let liveProgress else { return nil }
        return "\(Int((liveProgress * 100).rounded()))% complete"
    }

    private func performAction() {
        switch effectiveStatus {
        case .complete:
            // Deleting bypasses DownloadManager entirely (there's no in-flight transfer to
            // cancel), so `progress` never changes and the .onChange(of: liveProgress) hook
            // above never fires for this path — call onDidFinish directly so the parent still
            // re-fetches and stops showing a now-nonexistent download as complete.
            let episodeId = episode.id
            let descriptor = FetchDescriptor<DownloadedEpisodeRecord>(predicate: #Predicate { $0.id == episodeId })
            if let record = try? modelContext.fetch(descriptor).first, DownloadCleanup.delete([record], from: modelContext) {
                onDidFinish?()
            }
        case .downloading:
            downloadManager.cancelDownload(episodeId: episode.id)
        case .failed, nil:
            downloadManager.startDownload(episode: episode)
        }
    }
}
