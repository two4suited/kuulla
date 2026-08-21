import Foundation

// A user's per-show override of their global UnlistenedEpisodeCount setting.
// unlistenedEpisodeCount is nil when there's no override — inherit the user's global setting.
struct ShowSettings: Codable, Hashable {
    let id: String
    let userId: String
    let showId: String
    let unlistenedEpisodeCount: UnlistenedEpisodeCount?
    let version: Int
    let autoArchiveRule: AutoArchiveRule?
    let autoSkipIntroSeconds: Int?
    let autoSkipOutroSeconds: Int?

    init(
        id: String, userId: String, showId: String, unlistenedEpisodeCount: UnlistenedEpisodeCount?,
        version: Int, autoArchiveRule: AutoArchiveRule?,
        autoSkipIntroSeconds: Int? = nil, autoSkipOutroSeconds: Int? = nil
    ) {
        self.id = id
        self.userId = userId
        self.showId = showId
        self.unlistenedEpisodeCount = unlistenedEpisodeCount
        self.version = version
        self.autoArchiveRule = autoArchiveRule
        self.autoSkipIntroSeconds = autoSkipIntroSeconds
        self.autoSkipOutroSeconds = autoSkipOutroSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case id, userId, showId, unlistenedEpisodeCount, version, autoArchiveRule, autoSkipIntroSeconds, autoSkipOutroSeconds
    }

    // Defaults to nil (no override) when absent so a response that predates #187's field
    // addition still decodes cleanly rather than failing entirely.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        userId = try container.decode(String.self, forKey: .userId)
        showId = try container.decode(String.self, forKey: .showId)
        unlistenedEpisodeCount = try container.decodeIfPresent(UnlistenedEpisodeCount.self, forKey: .unlistenedEpisodeCount)
        version = try container.decode(Int.self, forKey: .version)
        autoArchiveRule = try container.decodeIfPresent(AutoArchiveRule.self, forKey: .autoArchiveRule)
        autoSkipIntroSeconds = try container.decodeIfPresent(Int.self, forKey: .autoSkipIntroSeconds)
        autoSkipOutroSeconds = try container.decodeIfPresent(Int.self, forKey: .autoSkipOutroSeconds)
    }
}
