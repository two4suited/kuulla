using Kuulla.Api.Models;

namespace Kuulla.Api.Services;

public interface ISettingsService
{
    Task<UserSettings> GetSettingsAsync(string userId, CancellationToken cancellationToken);

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
}
