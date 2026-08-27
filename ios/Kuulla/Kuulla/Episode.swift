import Foundation

// Custom Decodable because `duration` arrives as a .NET TimeSpan string
// (e.g. "45:00", "1.02:03:04", "00:45:00.500") rather than a plain number.
struct Episode: Decodable, Identifiable {
    let id: String
    let showId: String
    let title: String
    let publishedAt: Date?
    let duration: TimeInterval?
    let audioUrl: String
    let description: String?
    let bitrateKbps: Int?
    let fileSizeBytes: Int?
    let chapters: [EpisodeChapter]?
    // From the feed's podcast:transcript tag. The document itself is fetched on demand from the
    // transcript endpoint (see PodcastCatalogClient.getEpisodeTranscript); only its presence is
    // known here, and it's what gates whether the transcript view is shown at all.
    let transcriptUrl: String?
    let transcriptType: String?

    private enum CodingKeys: String, CodingKey {
        case id, showId, title, publishedAt, duration, audioUrl, description, bitrateKbps, fileSizeBytes, chapters
        case transcriptUrl, transcriptType
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        showId = try container.decode(String.self, forKey: .showId)
        title = try container.decode(String.self, forKey: .title)
        publishedAt = try container.decodeIfPresent(Date.self, forKey: .publishedAt)
        audioUrl = try container.decode(String.self, forKey: .audioUrl)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        bitrateKbps = try container.decodeIfPresent(Int.self, forKey: .bitrateKbps)
        fileSizeBytes = try container.decodeIfPresent(Int.self, forKey: .fileSizeBytes)
        chapters = try container.decodeIfPresent([EpisodeChapter].self, forKey: .chapters)
        transcriptUrl = try container.decodeIfPresent(String.self, forKey: .transcriptUrl)
        transcriptType = try container.decodeIfPresent(String.self, forKey: .transcriptType)

        if let durationText = try container.decodeIfPresent(String.self, forKey: .duration) {
            duration = Episode.parseDuration(durationText)
        } else {
            duration = nil
        }
    }

    // Parses .NET's TimeSpan format: [-][d.]hh:mm:ss[.fffffff], e.g. "00:45:00" or "1.02:03:04".
    static func parseDuration(_ text: String) -> TimeInterval? {
        var text = text
        var sign: Double = 1
        if text.hasPrefix("-") {
            sign = -1
            text.removeFirst()
        }

        var days: Double = 0
        if let dotIndex = text.firstIndex(of: "."), !text[..<dotIndex].contains(":") {
            // A non-numeric day prefix (e.g. "abc.00:00:00") is malformed input, not "0 days" —
            // `?? 0` here would silently accept it and parse the rest as if the prefix weren't
            // there at all.
            guard let parsedDays = Double(text[..<dotIndex]) else {
                return nil
            }
            days = parsedDays
            text = String(text[text.index(after: dotIndex)...])
        }

        let parts = text.split(separator: ":")
        if parts.count == 3,
           let hours = Double(parts[0]),
           let minutes = Double(parts[1]),
           let seconds = Double(parts[2]) {
            return sign * (days * 86400 + hours * 3600 + minutes * 60 + seconds)
        } else if parts.count == 2,
                  let minutes = Double(parts[0]),
                  let seconds = Double(parts[1]) {
            return sign * (days * 86400 + minutes * 60 + seconds)
        } else {
            return nil
        }
    }
}

// Parsed from a podcast:chapters feed; startTime arrives as the same .NET TimeSpan string
// format as Episode.duration, so it's decoded through the same parseDuration helper.
struct EpisodeChapter: Decodable {
    let startTime: TimeInterval
    let title: String
    let imageUrl: String?
    let url: String?

    private enum CodingKeys: String, CodingKey {
        case startTime, title, imageUrl, url
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let startTimeText = try container.decode(String.self, forKey: .startTime)
        // Fails the decode rather than defaulting to 0 — a chapter silently placed at "Intro at
        // 0:00" for a malformed timestamp would misplace its tick and could steal the
        // active-chapter highlight from whatever's actually playing at 0:00. A negative value is
        // rejected too — unlike Episode.duration (where a leading "-" is meaningful), a chapter
        // marker can't legitimately precede the start of the episode.
        guard let parsedStartTime = Episode.parseDuration(startTimeText), parsedStartTime >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .startTime, in: container, debugDescription: "Invalid TimeSpan value: \(startTimeText)")
        }
        startTime = parsedStartTime
        title = try container.decode(String.self, forKey: .title)
        imageUrl = try container.decodeIfPresent(String.self, forKey: .imageUrl)
        url = try container.decodeIfPresent(String.self, forKey: .url)
    }
}
