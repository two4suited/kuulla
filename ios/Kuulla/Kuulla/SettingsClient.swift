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
