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
}

private struct UpdateSettingsRequest: Encodable {
    let unlistenedEpisodeCount: UnlistenedEpisodeCount
}

private struct UpdateShowSettingsRequest: Encodable {
    let unlistenedEpisodeCount: UnlistenedEpisodeCount?
}
