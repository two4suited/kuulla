using Kuulla.Api.Models;

namespace Kuulla.Api.Services;

public interface IEpisodeStateService
{
    Task<EpisodeState?> GetStateAsync(string userId, string episodeId, CancellationToken cancellationToken);

    Task<IReadOnlyDictionary<string, EpisodeState>> GetStatesAsync(
        string userId, IReadOnlyList<string> episodeIds, CancellationToken cancellationToken);

    Task<EpisodeState> UpdateStateAsync(
        string userId,
        string episodeId,
        string showId,
        int positionSeconds,
        bool completed,
        string? deviceId,
        CancellationToken cancellationToken);

    Task MarkAutoPlayedAsync(
        string userId, IReadOnlyList<(string EpisodeId, string ShowId)> episodes, CancellationToken cancellationToken);

    Task<IReadOnlyList<EpisodeState>> GetShowStatesAsync(
        string userId, string showId, CancellationToken cancellationToken);

    Task SetArchivedAsync(
        string userId, IReadOnlyList<EpisodeState> states, bool archived, CancellationToken cancellationToken);

    Task<SyncEpisodesResult> SyncAsync(
        string userId,
        string deviceId,
        DateTimeOffset lastSyncedAt,
        string localHash,
        IReadOnlyList<EpisodeStateChange> changes,
        CancellationToken cancellationToken);
}
