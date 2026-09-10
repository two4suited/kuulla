import Foundation
import SwiftData

// On-device cache of one `Episode` row within a show's episode list (GET /api/shows/{id}/
// episodes). Read-through cache — see SubscriptionRecord's note. `sortIndex` preserves the
// server's returned order across pages; `chaptersData` is a JSON blob of `[CachedChapter]`
// because `EpisodeChapter` isn't stored directly.
@Model
final class CachedEpisodeRecord {
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
        self.cachedAt = cachedAt
    }

    convenience init(from episode: Episode, showId: String, sortIndex: Int, cachedAt: Date = .now) {
        let chaptersData = episode.chapters.flatMap { chapters in
            try? JSONEncoder().encode(chapters.map(CachedChapter.init(from:)))
        }
        self.init(
            id: episode.id,
            showId: showId,
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
}

// Codable mirror of EpisodeChapter for the cache blob — EpisodeChapter itself decodes the
// wire's .NET TimeSpan strings and has no Encodable conformance.
struct CachedChapter: Codable {
    let startTime: TimeInterval
    let title: String
    let imageUrl: String?
    let url: String?

    init(from chapter: EpisodeChapter) {
        startTime = chapter.startTime
        title = chapter.title
        imageUrl = chapter.imageUrl
        url = chapter.url
    }

    var episodeChapter: EpisodeChapter {
        EpisodeChapter(startTime: startTime, title: title, imageUrl: imageUrl, url: url)
    }
}
