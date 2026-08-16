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

    private enum CodingKeys: String, CodingKey {
        case id, showId, title, publishedAt, duration, audioUrl, description, bitrateKbps, fileSizeBytes
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

        if let durationText = try container.decodeIfPresent(String.self, forKey: .duration) {
            duration = Episode.parseDuration(durationText)
        } else {
            duration = nil
        }
    }

    // Parses .NET's TimeSpan format: [-][d.]hh:mm:ss[.fffffff]
    static func parseDuration(_ text: String) -> TimeInterval? {
        var text = text
        var sign: Double = 1
        if text.hasPrefix("-") {
            sign = -1
            text.removeFirst()
        }

        var days: Double = 0
        if let dotIndex = text.firstIndex(of: "."), !text[..<dotIndex].contains(":") {
            days = Double(text[..<dotIndex]) ?? 0
            text = String(text[text.index(after: dotIndex)...])
        }

        let parts = text.split(separator: ":")
        guard parts.count == 3,
              let hours = Double(parts[0]),
              let minutes = Double(parts[1]),
              let seconds = Double(parts[2])
        else {
            return nil
        }

        return sign * (days * 86400 + hours * 3600 + minutes * 60 + seconds)
    }
}
