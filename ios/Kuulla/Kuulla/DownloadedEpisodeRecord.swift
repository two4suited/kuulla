import Foundation
import SwiftData

// Tracks an episode downloaded for offline playback. Device-local only — not Syncable, since
// downloads are tied to the storage of a particular device rather than the user's account.
@Model
final class DownloadedEpisodeRecord {
    @Attribute(.unique) var id: String
    var showId: String
    // Relative to the app's Documents/Application Support container, not an absolute path — the
    // container path can change between launches.
    var localFilePath: String
    var fileSizeBytes: Int
    var downloadedAt: Date
    var status: DownloadStatus

    // JSON-encoded [SilenceRange] from SilenceMapAnalyzer (#777) — nil until analysis completes.
    // Stored as a plain field rather than a new @Model/relationship: it's small (a few dozen
    // ranges at most), always read/written as a whole, and this app has no VersionedSchema
    // migration plan yet, so an optional field (defaulting to nil) is the lightest-weight change
    // SwiftData's automatic lightweight migration can absorb.
    var silenceMapData: Data?
    var silenceMapComputedAt: Date?
    // Set when analysis errors out, so DownloadManager/AudioPlayer don't keep retrying a file
    // that will never decode (corrupt download, unsupported codec).
    var silenceMapFailed: Bool = false
    // Guards LocalSettings.addSilenceTimeSaved so a spliced episode's trimmed seconds are only
    // credited to the lifetime counter (#680) once per download, not once per playback session.
    var silenceTimeSavedCounted: Bool = false

    init(
        id: String,
        showId: String,
        localFilePath: String,
        fileSizeBytes: Int,
        downloadedAt: Date,
        status: DownloadStatus
    ) {
        self.id = id
        self.showId = showId
        self.localFilePath = localFilePath
        self.fileSizeBytes = fileSizeBytes
        self.downloadedAt = downloadedAt
        self.status = status
    }
}

extension DownloadedEpisodeRecord {
    // Decodes silenceMapData into the ranges SpliceCompositionBuilder needs, or [] when there's
    // no computed map yet (or the record itself doesn't exist) — callers treat an empty result as
    // "play this file unedited", exactly the same degraded mode as an unanalyzed stream.
    static func silenceMapRanges(from record: DownloadedEpisodeRecord?) -> [SilenceRange] {
        guard let data = record?.silenceMapData else { return [] }
        return (try? JSONDecoder().decode([SilenceRange].self, from: data)) ?? []
    }

    // Credits a spliced playback session's real-world time saved into the on-device lifetime
    // counter (#680), the first time it happens for this download — mirrors
    // DownloadManager.markFailed's own "fresh context, fetch by id, mutate, save" shape, since
    // AudioPlayer.onSpliceApplied can fire well after whatever context originally resolved this
    // episode's playback URL.
    static func creditSilenceTimeSavedIfNeeded(episodeId: String, seconds: TimeInterval, modelContainer: ModelContainer) {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<DownloadedEpisodeRecord>(predicate: #Predicate { $0.id == episodeId })
        guard let record = try? context.fetch(descriptor).first, !record.silenceTimeSavedCounted else { return }
        record.silenceTimeSavedCounted = true
        LocalSettings.addSilenceTimeSaved(seconds)
        try? context.save()
    }

    // Marks a download .failed from a fresh context, mirroring DownloadManager.markFailed's own
    // "fresh context, fetch by id, mutate, save" shape — used by AudioPlayer.onLocalFileFailed
    // wiring (#781), which fires well after whatever context originally resolved this episode's
    // playback URL and only has the episode id available, not a live record reference.
    static func markFailed(episodeId: String, modelContainer: ModelContainer) {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<DownloadedEpisodeRecord>(predicate: #Predicate { $0.id == episodeId })
        guard let record = try? context.fetch(descriptor).first else { return }
        record.status = .failed
        try? context.save()
    }

    // Wires `player.onLocalFileFailed` (#781) to mark this episode's download .failed the moment
    // AVFoundation can't open the local file it's playing, then re-invoke `replay` with the
    // episode's stream URL at the position playback had reached, so the episode keeps playing
    // instead of just stopping. A nil modelContainer leaves whatever was previously assigned
    // untouched, mirroring wireSpliceCredit's own guard.
    static func wireLocalFileFailureFallback(
        episodeId: String, streamURLString: String, modelContainer: ModelContainer?, on player: AudioPlayer,
        replay: @escaping (_ streamURL: URL, _ startPosition: TimeInterval) -> Void
    ) {
        guard let modelContainer else { return }
        player.onLocalFileFailed = { failedURL, startPosition in
            markFailed(episodeId: episodeId, modelContainer: modelContainer)
            guard let streamURL = URL(string: streamURLString), streamURL != failedURL else { return }
            replay(streamURL, startPosition)
        }
    }

    // Wires `player.onSpliceApplied` to credit this episode's download the moment a splice
    // session fires — shared by every play()/preloadNext() call site (EpisodeDetailView,
    // PlaybackQueue, CarPlaySceneDelegate) so the closure's shape lives in exactly one place. A
    // nil modelContainer (no DI wiring yet) leaves whatever was previously assigned untouched,
    // mirroring how none of those call sites can resolve a silence map without one either.
    static func wireSpliceCredit(episodeId: String, modelContainer: ModelContainer?, on player: AudioPlayer) {
        guard let modelContainer else { return }
        player.onSpliceApplied = { seconds in
            creditSilenceTimeSavedIfNeeded(episodeId: episodeId, seconds: seconds, modelContainer: modelContainer)
        }
    }
}

enum DownloadStatus: String, Codable {
    case downloading
    case complete
    case failed
}

extension DownloadStatus {
    // Local-only download status lookup for a set of episode ids, mirroring
    // EpisodeStatus.statusMap(for:in:) so FeedView/ShowDetailView can batch-fetch download state
    // for visible episodes without N separate queries.
    static func statusMap(for episodeIds: Set<String>, in context: ModelContext) -> [String: DownloadStatus] {
        let descriptor = FetchDescriptor<DownloadedEpisodeRecord>(predicate: #Predicate { episodeIds.contains($0.id) })
        let records = (try? context.fetch(descriptor)) ?? []
        return Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0.status) })
    }
}
