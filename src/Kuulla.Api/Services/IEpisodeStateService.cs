using Kuulla.Api.Models;

namespace Kuulla.Api.Services;

public interface IEpisodeStateService
{
    Task<EpisodeState?> GetStateAsync(string userId, string episodeId, CancellationToken cancellationToken);

    Task<EpisodeState> UpdateStateAsync(
        string userId,
        string episodeId,
        string showId,
        int positionSeconds,
        bool completed,
        string? deviceId,
        CancellationToken cancellationToken);

    Task<EpisodeState> MarkAutoPlayedAsync(
        string userId, string episodeId, string showId, CancellationToken cancellationToken);

    Task<SyncEpisodesResult> SyncAsync(
        string userId,
        string deviceId,
        DateTimeOffset lastSyncedAt,
        string localHash,
        IReadOnlyList<EpisodeStateChange> changes,
        CancellationToken cancellationToken);
}
