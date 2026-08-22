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
