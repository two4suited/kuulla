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
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
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
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: liveProgress ?? 0)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
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
