import Foundation

struct UserSettings: Codable, Hashable {
    let userId: String
    let unlistenedEpisodeCount: UnlistenedEpisodeCount
    let version: Int
    let autoArchiveRule: AutoArchiveRule
    let autoSkipIntroSeconds: Int
    let autoSkipOutroSeconds: Int
    let playbackSpeed: Float

    init(
        userId: String, unlistenedEpisodeCount: UnlistenedEpisodeCount, version: Int, autoArchiveRule: AutoArchiveRule,
        autoSkipIntroSeconds: Int = 0, autoSkipOutroSeconds: Int = 0, playbackSpeed: Float = 1.0
    ) {
        self.userId = userId
        self.unlistenedEpisodeCount = unlistenedEpisodeCount
        self.version = version
        self.autoArchiveRule = autoArchiveRule
        self.autoSkipIntroSeconds = autoSkipIntroSeconds
        self.autoSkipOutroSeconds = autoSkipOutroSeconds
        self.playbackSpeed = playbackSpeed
    }

    private enum CodingKeys: String, CodingKey {
        case userId, unlistenedEpisodeCount, version, autoArchiveRule, autoSkipIntroSeconds, autoSkipOutroSeconds, playbackSpeed
    }

    // Defaults to .never when absent so a response that predates #187's field addition still
    // decodes cleanly rather than failing entirely (mirrors EpisodeSyncAdapter's DTO precedent).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        userId = try container.decode(String.self, forKey: .userId)
        unlistenedEpisodeCount = try container.decode(UnlistenedEpisodeCount.self, forKey: .unlistenedEpisodeCount)
        version = try container.decode(Int.self, forKey: .version)
        autoArchiveRule = try container.decodeIfPresent(AutoArchiveRule.self, forKey: .autoArchiveRule) ?? .never
        // Default to 0 (off) when absent, same rationale as autoArchiveRule above.
        autoSkipIntroSeconds = try container.decodeIfPresent(Int.self, forKey: .autoSkipIntroSeconds) ?? 0
        autoSkipOutroSeconds = try container.decodeIfPresent(Int.self, forKey: .autoSkipOutroSeconds) ?? 0
        // Default to 1.0 (normal speed) when absent, same rationale as autoArchiveRule above.
        playbackSpeed = try container.decodeIfPresent(Float.self, forKey: .playbackSpeed) ?? 1.0
    }
}

// How many unlistened episodes to surface per show. Mirrors the API's
// Kuulla.Api.Models.UnlistenedEpisodeCount enum, including its raw values, since the wire
// format is a plain integer.
enum UnlistenedEpisodeCount: Int, Codable, CaseIterable, Identifiable {
    case one = 1
    case two = 2
    case five = 5
    case ten = 10
    case unlimited = -1

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .one: "1 episode"
        case .two: "2 episodes"
        case .five: "5 episodes"
        case .ten: "10 episodes"
        case .unlimited: "All episodes"
        }
    }
}
