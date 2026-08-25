using Kuulla.Api.Models;

namespace Kuulla.Api.Services;

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

    Task<UserSettings> UpdateSmartSpeedAsync(
        string userId, bool smartSpeed, CancellationToken cancellationToken);

    Task<ShowSettings> UpdateShowSmartSpeedAsync(
        string userId, string showId, bool? smartSpeed, CancellationToken cancellationToken);

    Task<bool> GetEffectiveSmartSpeedAsync(
        string userId, string showId, CancellationToken cancellationToken);
}
