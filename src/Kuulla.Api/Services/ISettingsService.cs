using Kuulla.Api.Models;

namespace Kuulla.Api.Services;

public interface ISettingsService
{
    Task<UserSettings> GetSettingsAsync(string userId, CancellationToken cancellationToken);

    Task<UserSettings> UpdateUnlistenedEpisodeCountAsync(
        string userId, UnlistenedEpisodeCount unlistenedEpisodeCount, CancellationToken cancellationToken);
}
