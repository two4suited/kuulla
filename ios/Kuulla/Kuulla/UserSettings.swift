import Foundation

struct UserSettings: Codable, Hashable {
    let userId: String
    let unlistenedEpisodeCount: UnlistenedEpisodeCount
    let version: Int
    let autoArchiveRule: AutoArchiveRule
    let autoSkipIntroSeconds: Int
    let autoSkipOutroSeconds: Int
    let playbackSpeed: Float
    let autoDeleteRule: AutoDeleteRule
    let autoDeleteAfterDays: Int
    let autoDownloadNewEpisodes: Bool

    init(
        userId: String, unlistenedEpisodeCount: UnlistenedEpisodeCount, version: Int, autoArchiveRule: AutoArchiveRule,
        autoSkipIntroSeconds: Int = 0, autoSkipOutroSeconds: Int = 0, playbackSpeed: Float = 1.0,
        autoDeleteRule: AutoDeleteRule = .never, autoDeleteAfterDays: Int = 7, autoDownloadNewEpisodes: Bool = false
    ) {
        self.userId = userId
        self.unlistenedEpisodeCount = unlistenedEpisodeCount
        self.version = version
        self.autoArchiveRule = autoArchiveRule
        self.autoSkipIntroSeconds = autoSkipIntroSeconds
        self.autoSkipOutroSeconds = autoSkipOutroSeconds
        self.playbackSpeed = playbackSpeed
        self.autoDeleteRule = autoDeleteRule
        self.autoDeleteAfterDays = autoDeleteAfterDays
        self.autoDownloadNewEpisodes = autoDownloadNewEpisodes
    }

    private enum CodingKeys: String, CodingKey {
        case userId, unlistenedEpisodeCount, version, autoArchiveRule, autoSkipIntroSeconds, autoSkipOutroSeconds, playbackSpeed
        case autoDeleteRule, autoDeleteAfterDays, autoDownloadNewEpisodes
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
        // Default to .never/7 when absent (#179), same rationale as autoArchiveRule above.
        autoDeleteRule = try container.decodeIfPresent(AutoDeleteRule.self, forKey: .autoDeleteRule) ?? .never
        autoDeleteAfterDays = try container.decodeIfPresent(Int.self, forKey: .autoDeleteAfterDays) ?? 7
        // Default to false (off) when absent (#268), same rationale as autoArchiveRule above.
        autoDownloadNewEpisodes = try container.decodeIfPresent(Bool.self, forKey: .autoDownloadNewEpisodes) ?? false
    }

    // Copies every field except the ones explicitly overridden. SettingsView's update*()
    // methods reconstruct an optimistic local UserSettings after changing just one field — with
    // a plain memberwise init, omitting any field (easy to do as more get added over time)
    // silently resets it to that init's default until the real server response arrives moments
    // later, which happened for real once already (playbackSpeed, before #179 fixed it). Routing
    // every such reconstruction through this method instead removes that whole bug class.
    func with(
        unlistenedEpisodeCount: UnlistenedEpisodeCount? = nil,
        autoArchiveRule: AutoArchiveRule? = nil,
        autoSkipIntroSeconds: Int? = nil,
        autoSkipOutroSeconds: Int? = nil,
        playbackSpeed: Float? = nil,
        autoDeleteRule: AutoDeleteRule? = nil,
        autoDeleteAfterDays: Int? = nil,
        autoDownloadNewEpisodes: Bool? = nil
    ) -> UserSettings {
        UserSettings(
            userId: userId, unlistenedEpisodeCount: unlistenedEpisodeCount ?? self.unlistenedEpisodeCount,
            version: version, autoArchiveRule: autoArchiveRule ?? self.autoArchiveRule,
            autoSkipIntroSeconds: autoSkipIntroSeconds ?? self.autoSkipIntroSeconds,
            autoSkipOutroSeconds: autoSkipOutroSeconds ?? self.autoSkipOutroSeconds,
            playbackSpeed: playbackSpeed ?? self.playbackSpeed,
            autoDeleteRule: autoDeleteRule ?? self.autoDeleteRule,
            autoDeleteAfterDays: autoDeleteAfterDays ?? self.autoDeleteAfterDays,
            autoDownloadNewEpisodes: autoDownloadNewEpisodes ?? self.autoDownloadNewEpisodes)
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
