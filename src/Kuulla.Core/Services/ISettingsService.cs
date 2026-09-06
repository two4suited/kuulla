using Kuulla.Core.Models;

namespace Kuulla.Core.Services;

public interface ISettingsService
{
    Task<UserSettings> GetSettingsAsync(string userId, CancellationToken cancellationToken);

    Task<SyncSettingsResult> SyncAsync(
        string userId,
        string deviceId,
        DateTimeOffset lastSyncedAt,
        string localHash,
        IReadOnlyList<UserSettingsChange> changes,
        CancellationToken cancellationToken);

    Task<UserSettings> UpdateUnlistenedEpisodeCountAsync(
        string userId, UnlistenedEpisodeCount unlistenedEpisodeCount, CancellationToken cancellationToken);

    Task<UserSettings> UpdateSubscriptionSortOrderAsync(
        string userId, SubscriptionSortOrder subscriptionSortOrder, CancellationToken cancellationToken);

    Task<UserSettings> UpdateSubscriptionManualOrderAsync(
        string userId, IReadOnlyList<string> subscriptionManualOrder, CancellationToken cancellationToken);

    Task<UserSettings> UpdateHideCaughtUpShowsAsync(
        string userId, bool hideCaughtUpShows, CancellationToken cancellationToken);

    Task<ShowSettings> GetShowSettingsAsync(string userId, string showId, CancellationToken cancellationToken);

    Task<ShowSettings> UpdateShowUnlistenedEpisodeCountAsync(
        string userId, string showId, UnlistenedEpisodeCount? unlistenedEpisodeCount, CancellationToken cancellationToken);

    Task<UnlistenedEpisodeCount> GetEffectiveUnlistenedEpisodeCountAsync(
        string userId, string showId, CancellationToken cancellationToken);

    Task<UserSettings> UpdateAutoArchiveRuleAsync(
        string userId, AutoArchiveRule autoArchiveRule, CancellationToken cancellationToken);

    Task<ShowSettings> UpdateShowAutoArchiveRuleAsync(
        string userId, string showId, AutoArchiveRule? autoArchiveRule, CancellationToken cancellationToken);

    Task<AutoArchiveRule> GetEffectiveAutoArchiveRuleAsync(
        string userId, string showId, CancellationToken cancellationToken);

    Task<UserSettings> UpdateAutoSkipAsync(
        string userId, int autoSkipIntroSeconds, int autoSkipOutroSeconds, CancellationToken cancellationToken);

    Task<ShowSettings> UpdateShowAutoSkipAsync(
        string userId, string showId, int? autoSkipIntroSeconds, int? autoSkipOutroSeconds, CancellationToken cancellationToken);

    Task<(int IntroSeconds, int OutroSeconds)> GetEffectiveAutoSkipAsync(
        string userId, string showId, CancellationToken cancellationToken);

    Task<UserSettings> UpdatePlaybackSpeedAsync(
        string userId, float playbackSpeed, CancellationToken cancellationToken);

    Task<ShowSettings> UpdateShowPlaybackSpeedAsync(
        string userId, string showId, float? playbackSpeed, CancellationToken cancellationToken);

    Task<float> GetEffectivePlaybackSpeedAsync(
        string userId, string showId, CancellationToken cancellationToken);

    Task<UserSettings> UpdateAutoDeleteRuleAsync(
        string userId, AutoDeleteRule autoDeleteRule, int autoDeleteAfterDays, CancellationToken cancellationToken);

    Task<UserSettings> UpdateAutoDownloadNewEpisodesAsync(
        string userId, bool autoDownloadNewEpisodes, CancellationToken cancellationToken);

    Task<ShowSettings> UpdateShowAutoDownloadNewEpisodesAsync(
        string userId, string showId, bool? autoDownloadNewEpisodes, CancellationToken cancellationToken);

    Task<bool> GetEffectiveAutoDownloadNewEpisodesAsync(
        string userId, string showId, CancellationToken cancellationToken);

    Task<UserSettings> UpdateAutoAddNewEpisodesToUpNextAsync(
        string userId, bool autoAddNewEpisodesToUpNext, CancellationToken cancellationToken);

    Task<ShowSettings> UpdateShowAutoAddNewEpisodesToUpNextAsync(
        string userId, string showId, bool? autoAddNewEpisodesToUpNext, CancellationToken cancellationToken);

    Task<bool> GetEffectiveAutoAddNewEpisodesToUpNextAsync(
        string userId, string showId, CancellationToken cancellationToken);

    Task<UserSettings> UpdateUpNextInsertPositionAsync(
        string userId, UpNextInsertPosition upNextInsertPosition, CancellationToken cancellationToken);

    Task<UserSettings> UpdateSmartSpeedAsync(
        string userId, bool smartSpeed, CancellationToken cancellationToken);

    Task<ShowSettings> UpdateShowSmartSpeedAsync(
        string userId, string showId, bool? smartSpeed, CancellationToken cancellationToken);

    Task<bool> GetEffectiveSmartSpeedAsync(
        string userId, string showId, CancellationToken cancellationToken);

    Task<UserSettings> UpdateNotificationsEnabledAsync(
        string userId, bool notificationsEnabled, CancellationToken cancellationToken);

    Task<UserSettings> UpdateSleepTimerDefaultDurationAsync(
        string userId, int sleepTimerDefaultDurationMinutes, CancellationToken cancellationToken);

    Task<ShowSettings> UpdateShowNotificationsEnabledAsync(
        string userId, string showId, bool? notificationsEnabled, CancellationToken cancellationToken);

    Task<bool> GetEffectiveNotificationsEnabledAsync(
        string userId, string showId, CancellationToken cancellationToken);
}
