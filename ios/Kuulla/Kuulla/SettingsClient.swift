import Foundation

struct SettingsClient {
    private let apiClient: ApiClient

    init(apiClient: ApiClient = .shared) {
        self.apiClient = apiClient
    }

    func getSettings() async throws -> UserSettings {
        try await apiClient.get(["api", "settings"])
    }

    func updateUnlistenedEpisodeCount(_ value: UnlistenedEpisodeCount) async throws -> UserSettings {
        try await apiClient.put(["api", "settings"], body: UpdateSettingsRequest(unlistenedEpisodeCount: value))
    }

    func getShowSettings(showId: String) async throws -> ShowSettings {
        try await apiClient.get(["api", "settings", "shows", showId])
    }

    func updateShowUnlistenedEpisodeCount(showId: String, value: UnlistenedEpisodeCount?) async throws -> ShowSettings {
        try await apiClient.put(
            ["api", "settings", "shows", showId],
            body: UpdateShowSettingsRequest(unlistenedEpisodeCount: value))
    }

    func updateAutoArchiveRule(_ value: AutoArchiveRule) async throws -> UserSettings {
        try await apiClient.put(["api", "settings", "auto-archive"], body: UpdateAutoArchiveRuleRequest(autoArchiveRule: value))
    }

    func updateShowAutoArchiveRule(showId: String, value: AutoArchiveRule?) async throws -> ShowSettings {
        try await apiClient.put(
            ["api", "settings", "shows", showId, "auto-archive"],
            body: UpdateShowAutoArchiveRuleRequest(autoArchiveRule: value))
    }

    func updateAutoSkip(introSeconds: Int, outroSeconds: Int) async throws -> UserSettings {
        try await apiClient.put(
            ["api", "settings", "auto-skip"],
            body: UpdateAutoSkipRequest(autoSkipIntroSeconds: introSeconds, autoSkipOutroSeconds: outroSeconds))
    }

    func updateShowAutoSkip(showId: String, introSeconds: Int?, outroSeconds: Int?) async throws -> ShowSettings {
        try await apiClient.put(
            ["api", "settings", "shows", showId, "auto-skip"],
            body: UpdateShowAutoSkipRequest(autoSkipIntroSeconds: introSeconds, autoSkipOutroSeconds: outroSeconds))
    }

    func updatePlaybackSpeed(_ value: Float) async throws -> UserSettings {
        try await apiClient.put(["api", "settings", "playback-speed"], body: UpdatePlaybackSpeedRequest(playbackSpeed: value))
    }

    func updateShowPlaybackSpeed(showId: String, value: Float?) async throws -> ShowSettings {
        try await apiClient.put(
            ["api", "settings", "shows", showId, "playback-speed"],
            body: UpdateShowPlaybackSpeedRequest(playbackSpeed: value))
    }

    func updateAutoDeleteRule(_ rule: AutoDeleteRule, afterDays: Int) async throws -> UserSettings {
        try await apiClient.put(
            ["api", "settings", "auto-delete"],
            body: UpdateAutoDeleteRuleRequest(autoDeleteRule: rule, autoDeleteAfterDays: afterDays))
    }
}

private struct UpdateSettingsRequest: Encodable {
    let unlistenedEpisodeCount: UnlistenedEpisodeCount
}

private struct UpdateShowSettingsRequest: Encodable {
    let unlistenedEpisodeCount: UnlistenedEpisodeCount?
}

private struct UpdateAutoArchiveRuleRequest: Encodable {
    let autoArchiveRule: AutoArchiveRule
}

private struct UpdateShowAutoArchiveRuleRequest: Encodable {
    let autoArchiveRule: AutoArchiveRule?
}

private struct UpdateAutoSkipRequest: Encodable {
    let autoSkipIntroSeconds: Int
    let autoSkipOutroSeconds: Int
}

private struct UpdateShowAutoSkipRequest: Encodable {
    let autoSkipIntroSeconds: Int?
    let autoSkipOutroSeconds: Int?
}

private struct UpdatePlaybackSpeedRequest: Encodable {
    let playbackSpeed: Float
}

private struct UpdateShowPlaybackSpeedRequest: Encodable {
    let playbackSpeed: Float?
}

private struct UpdateAutoDeleteRuleRequest: Encodable {
    let autoDeleteRule: AutoDeleteRule
    let autoDeleteAfterDays: Int
}
