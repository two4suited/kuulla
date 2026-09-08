using Kuulla.Core.Models;

namespace Kuulla.Core.Services;

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

    // Marks every supplied episode of a show played for the user in one pass — the "start from a
    // clean slate" action on the Show screen (#490). Distinct from MarkAutoPlayedAsync: this is a
    // real user action, so the rows land with AutoPlayed = false and PositionSeconds at the
    // episode duration. Episodes the user has already marked played (Completed && !AutoPlayed) are
    // left untouched, so a re-run is a no-op. Returns the rows actually written.
    Task<IReadOnlyList<EpisodeState>> MarkAllPlayedAsync(
        string userId,
        string showId,
        IReadOnlyList<(string EpisodeId, int DurationSeconds)> episodes,
        string? deviceId,
        CancellationToken cancellationToken);

    Task<IReadOnlyList<EpisodeState>> GetShowStatesAsync(
        string userId, string showId, CancellationToken cancellationToken);

    // Show ids the user has at least one in-progress episode for (a saved position, not yet
    // completed) — powers the "in progress" show badge on the Library and Subscriptions grids.
    Task<IReadOnlyList<string>> GetInProgressShowIdsAsync(string userId, CancellationToken cancellationToken);

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
