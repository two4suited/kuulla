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

    func updateSubscriptionSortOrder(_ value: SubscriptionSortOrder) async throws -> UserSettings {
        try await apiClient.put(
            ["api", "settings", "subscription-sort-order"],
            body: UpdateSubscriptionSortOrderRequest(subscriptionSortOrder: value))
    }

    func updateSubscriptionManualOrder(_ showIds: [String]) async throws -> UserSettings {
        try await apiClient.put(
            ["api", "settings", "subscription-manual-order"],
            body: UpdateSubscriptionManualOrderRequest(showIds: showIds))
    }

    func updateHideCaughtUpShows(_ value: Bool) async throws -> UserSettings {
        try await apiClient.put(
            ["api", "settings", "hide-caught-up-shows"],
            body: UpdateHideCaughtUpShowsRequest(hideCaughtUpShows: value))
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

    func updateShowAutoDeleteRule(showId: String, rule: AutoDeleteRule?, afterDays: Int?) async throws -> ShowSettings {
        try await apiClient.put(
            ["api", "settings", "shows", showId, "auto-delete"],
            body: UpdateShowAutoDeleteRuleRequest(autoDeleteRule: rule, autoDeleteAfterDays: afterDays))
    }

    func updateAutoDownloadNewEpisodes(_ value: Bool) async throws -> UserSettings {
        try await apiClient.put(
            ["api", "settings", "auto-download"],
            body: UpdateAutoDownloadNewEpisodesRequest(autoDownloadNewEpisodes: value))
    }

    func updateShowAutoDownloadNewEpisodes(showId: String, value: Bool?) async throws -> ShowSettings {
        try await apiClient.put(
            ["api", "settings", "shows", showId, "auto-download"],
            body: UpdateShowAutoDownloadNewEpisodesRequest(autoDownloadNewEpisodes: value))
    }

    func updateAutoAddNewEpisodesToUpNext(_ value: Bool) async throws -> UserSettings {
        try await apiClient.put(
            ["api", "settings", "auto-add-up-next"],
            body: UpdateAutoAddNewEpisodesToUpNextRequest(autoAddNewEpisodesToUpNext: value))
    }

    func updateShowAutoAddNewEpisodesToUpNext(showId: String, value: Bool?) async throws -> ShowSettings {
        try await apiClient.put(
            ["api", "settings", "shows", showId, "auto-add-up-next"],
            body: UpdateShowAutoAddNewEpisodesToUpNextRequest(autoAddNewEpisodesToUpNext: value))
    }

    func updateUpNextInsertPosition(_ value: UpNextInsertPosition) async throws -> UserSettings {
        try await apiClient.put(
            ["api", "settings", "up-next-insert-position"],
            body: UpdateUpNextInsertPositionRequest(upNextInsertPosition: value))
    }

    func updateSmartSpeed(_ value: Bool) async throws -> UserSettings {
        try await apiClient.put(["api", "settings", "smart-speed"], body: UpdateSmartSpeedRequest(smartSpeed: value))
    }

    func updateShowSmartSpeed(showId: String, value: Bool?) async throws -> ShowSettings {
        try await apiClient.put(
            ["api", "settings", "shows", showId, "smart-speed"],
            body: UpdateShowSmartSpeedRequest(smartSpeed: value))
    }

    func updateNotificationsEnabled(_ value: Bool) async throws -> UserSettings {
        try await apiClient.put(
            ["api", "settings", "notifications"],
            body: UpdateNotificationsEnabledRequest(notificationsEnabled: value))
    }

    func updateShowNotificationsEnabled(showId: String, value: Bool?) async throws -> ShowSettings {
        try await apiClient.put(
            ["api", "settings", "shows", showId, "notifications"],
            body: UpdateShowNotificationsEnabledRequest(notificationsEnabled: value))
    }

    func updateSleepTimerDefaultDuration(_ minutes: Int) async throws -> UserSettings {
        try await apiClient.put(
            ["api", "settings", "sleep-timer-default-duration"],
            body: UpdateSleepTimerDefaultDurationRequest(sleepTimerDefaultDurationMinutes: minutes))
    }
}

private struct UpdateSettingsRequest: Encodable {
    let unlistenedEpisodeCount: UnlistenedEpisodeCount
}

private struct UpdateSubscriptionSortOrderRequest: Encodable {
    let subscriptionSortOrder: SubscriptionSortOrder
}

private struct UpdateSubscriptionManualOrderRequest: Encodable {
    let showIds: [String]
}

private struct UpdateHideCaughtUpShowsRequest: Encodable {
    let hideCaughtUpShows: Bool
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

private struct UpdateShowAutoDeleteRuleRequest: Encodable {
    let autoDeleteRule: AutoDeleteRule?
    let autoDeleteAfterDays: Int?
}

private struct UpdateAutoDownloadNewEpisodesRequest: Encodable {
    let autoDownloadNewEpisodes: Bool
}

private struct UpdateShowAutoDownloadNewEpisodesRequest: Encodable {
    let autoDownloadNewEpisodes: Bool?
}

private struct UpdateAutoAddNewEpisodesToUpNextRequest: Encodable {
    let autoAddNewEpisodesToUpNext: Bool
}

private struct UpdateShowAutoAddNewEpisodesToUpNextRequest: Encodable {
    let autoAddNewEpisodesToUpNext: Bool?
}

private struct UpdateUpNextInsertPositionRequest: Encodable {
    let upNextInsertPosition: UpNextInsertPosition
}

private struct UpdateSmartSpeedRequest: Encodable {
    let smartSpeed: Bool
}

private struct UpdateShowSmartSpeedRequest: Encodable {
    let smartSpeed: Bool?
}

private struct UpdateNotificationsEnabledRequest: Encodable {
    let notificationsEnabled: Bool
}

private struct UpdateShowNotificationsEnabledRequest: Encodable {
    let notificationsEnabled: Bool?
}

private struct UpdateSleepTimerDefaultDurationRequest: Encodable {
    let sleepTimerDefaultDurationMinutes: Int
}
