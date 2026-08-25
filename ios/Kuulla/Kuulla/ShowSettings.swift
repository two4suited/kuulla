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
    let playbackSpeed: Float?
    let autoDownloadNewEpisodes: Bool?
    let smartSpeed: Bool?

    init(
        id: String, userId: String, showId: String, unlistenedEpisodeCount: UnlistenedEpisodeCount?,
        version: Int, autoArchiveRule: AutoArchiveRule?,
        autoSkipIntroSeconds: Int? = nil, autoSkipOutroSeconds: Int? = nil, playbackSpeed: Float? = nil,
        autoDownloadNewEpisodes: Bool? = nil, smartSpeed: Bool? = nil
    ) {
        self.id = id
        self.userId = userId
        self.showId = showId
        self.unlistenedEpisodeCount = unlistenedEpisodeCount
        self.version = version
        self.autoArchiveRule = autoArchiveRule
        self.autoSkipIntroSeconds = autoSkipIntroSeconds
        self.autoSkipOutroSeconds = autoSkipOutroSeconds
        self.playbackSpeed = playbackSpeed
        self.autoDownloadNewEpisodes = autoDownloadNewEpisodes
        self.smartSpeed = smartSpeed
    }

    private enum CodingKeys: String, CodingKey {
        case id, userId, showId, unlistenedEpisodeCount, version, autoArchiveRule, autoSkipIntroSeconds, autoSkipOutroSeconds, playbackSpeed
        case autoDownloadNewEpisodes, smartSpeed
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
        playbackSpeed = try container.decodeIfPresent(Float.self, forKey: .playbackSpeed)
        autoDownloadNewEpisodes = try container.decodeIfPresent(Bool.self, forKey: .autoDownloadNewEpisodes)
        smartSpeed = try container.decodeIfPresent(Bool.self, forKey: .smartSpeed)
    }

    // Copies every field except the ones explicitly overridden. Every field here is itself
    // optional (nil means "no override"), so a plain `T? = nil` default couldn't distinguish
    // "don't touch this field" from "clear this override" — the double-optional parameter can:
    // omitting an argument leaves the outer Optional nil ("don't touch"), while passing a T?
    // (including .none) is implicitly promoted to T??'s .some(...) ("set to exactly this,
    // clearing the override if it's .none"). Without this, ShowSettingsSheet's update*()
    // methods would each need every field spelled out by hand, the same bug class that already
    // hit UserSettings.swift once (see its own `with` for the non-nested version).
    func with(
        unlistenedEpisodeCount: UnlistenedEpisodeCount?? = nil,
        autoArchiveRule: AutoArchiveRule?? = nil,
        autoSkipIntroSeconds: Int?? = nil,
        autoSkipOutroSeconds: Int?? = nil,
        playbackSpeed: Float?? = nil,
        autoDownloadNewEpisodes: Bool?? = nil,
        smartSpeed: Bool?? = nil
    ) -> ShowSettings {
        ShowSettings(
            id: id, userId: userId, showId: showId,
            unlistenedEpisodeCount: unlistenedEpisodeCount ?? self.unlistenedEpisodeCount,
            version: version,
            autoArchiveRule: autoArchiveRule ?? self.autoArchiveRule,
            autoSkipIntroSeconds: autoSkipIntroSeconds ?? self.autoSkipIntroSeconds,
            autoSkipOutroSeconds: autoSkipOutroSeconds ?? self.autoSkipOutroSeconds,
            playbackSpeed: playbackSpeed ?? self.playbackSpeed,
            autoDownloadNewEpisodes: autoDownloadNewEpisodes ?? self.autoDownloadNewEpisodes,
            smartSpeed: smartSpeed ?? self.smartSpeed)
    }
}
