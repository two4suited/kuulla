import Foundation
import SwiftData

// On-device cache of one row of the "New Episodes" feed (GET /api/subscriptions/episodes).
// Read-through cache — see SubscriptionRecord's note. Mirrors CachedEpisodeRecord's inline
// episode-field layout, plus the per-row show identity and `autoPlayed` flag that `NewEpisode`
// carries (#441, #534). `sortIndex` preserves the server's returned order.
@Model
final class CachedNewEpisodeRecord {
    @Attribute(.unique) var id: String
    var showId: String
    var sortIndex: Int
    var title: String
    var publishedAt: Date?
    var durationSeconds: Double?
    var audioUrl: String
    var episodeDescription: String?
    var bitrateKbps: Int?
    var fileSizeBytes: Int?
    var chaptersData: Data?
    var transcriptUrl: String?
    var transcriptType: String?
    var autoPlayed: Bool
    var showTitle: String
    var showArtworkUrl: String?
    var cachedAt: Date

    init(
        id: String,
        showId: String,
        sortIndex: Int,
        title: String,
        publishedAt: Date?,
        durationSeconds: Double?,
        audioUrl: String,
        episodeDescription: String?,
        bitrateKbps: Int?,
        fileSizeBytes: Int?,
        chaptersData: Data?,
        transcriptUrl: String?,
        transcriptType: String?,
        autoPlayed: Bool,
        showTitle: String,
        showArtworkUrl: String?,
        cachedAt: Date = .now
    ) {
        self.id = id
        self.showId = showId
        self.sortIndex = sortIndex
        self.title = title
        self.publishedAt = publishedAt
        self.durationSeconds = durationSeconds
        self.audioUrl = audioUrl
        self.episodeDescription = episodeDescription
        self.bitrateKbps = bitrateKbps
        self.fileSizeBytes = fileSizeBytes
        self.chaptersData = chaptersData
        self.transcriptUrl = transcriptUrl
        self.transcriptType = transcriptType
        self.autoPlayed = autoPlayed
        self.showTitle = showTitle
        self.showArtworkUrl = showArtworkUrl
        self.cachedAt = cachedAt
    }

    convenience init(from newEpisode: NewEpisode, sortIndex: Int, cachedAt: Date = .now) {
        let episode = newEpisode.episode
        let chaptersData = episode.chapters.flatMap { chapters in
            try? JSONEncoder().encode(chapters.map(CachedChapter.init(from:)))
        }
        self.init(
            id: episode.id,
            showId: episode.showId,
            sortIndex: sortIndex,
            title: episode.title,
            publishedAt: episode.publishedAt,
            durationSeconds: episode.duration,
            audioUrl: episode.audioUrl,
            episodeDescription: episode.description,
            bitrateKbps: episode.bitrateKbps,
            fileSizeBytes: episode.fileSizeBytes,
            chaptersData: chaptersData,
            transcriptUrl: episode.transcriptUrl,
            transcriptType: episode.transcriptType,
            autoPlayed: newEpisode.autoPlayed,
            showTitle: newEpisode.showTitle,
            showArtworkUrl: newEpisode.showArtworkUrl,
            cachedAt: cachedAt)
    }

    var episode: Episode {
        let chapters = chaptersData
            .flatMap { try? JSONDecoder().decode([CachedChapter].self, from: $0) }
            .map { $0.map(\.episodeChapter) }
        return Episode(
            id: id,
            showId: showId,
            title: title,
            publishedAt: publishedAt,
            duration: durationSeconds,
            audioUrl: audioUrl,
            description: episodeDescription,
            bitrateKbps: bitrateKbps,
            fileSizeBytes: fileSizeBytes,
            chapters: chapters,
            transcriptUrl: transcriptUrl,
            transcriptType: transcriptType)
    }

    var newEpisode: NewEpisode {
        NewEpisode(
            episode: episode, autoPlayed: autoPlayed, showTitle: showTitle,
            showArtworkUrl: showArtworkUrl)
    }
}
