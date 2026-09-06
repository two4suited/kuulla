using System.Net;
using Kuulla.Core.Models;
using Kuulla.Core.Services.Sync;
using Microsoft.Azure.Cosmos;
using Microsoft.Extensions.DependencyInjection;

namespace Kuulla.Core.Services;

public class EpisodeStateService(
    [FromKeyedServices("episodestates")] Container episodeStatesContainer) : IEpisodeStateService
{
    private readonly SyncReconciler<EpisodeState, EpisodeStateChange> _reconciler = new();

    public Task<EpisodeState?> GetStateAsync(string userId, string episodeId, CancellationToken cancellationToken) =>
        ReadStateAsync(userId, episodeId, cancellationToken);

    // Lets a page render N episodes' state with one HTTP round trip instead of N (e.g. ShowDetail's
    // auto-played indicator) — one point read per id under the hood, fanned out in parallel behind
    // a single request.
    public async Task<IReadOnlyDictionary<string, EpisodeState>> GetStatesAsync(
        string userId, IReadOnlyList<string> episodeIds, CancellationToken cancellationToken)
    {
        var states = await Task.WhenAll(episodeIds.Select(async episodeId =>
        {
            var state = await GetStateAsync(userId, episodeId, cancellationToken);
            return (episodeId, state);
        }));

        return states.Where(x => x.state is not null).ToDictionary(x => x.episodeId, x => x.state!);
    }

    public async Task<EpisodeState> UpdateStateAsync(
        string userId,
        string episodeId,
        string showId,
        int positionSeconds,
        bool completed,
        string? deviceId,
        CancellationToken cancellationToken)
    {
        // Read the existing state first so a manual "mark unplayed" clears PlayedAt/Archived
        // (giving the auto-archive rule a fresh start) while a position update on an
        // already-played episode doesn't reset the PlayedAt timestamp the auto-archive rule is
        // measuring elapsed time from.
        var existing = await ReadStateAsync(userId, episodeId, cancellationToken);
        DateTimeOffset? playedAt = completed ? existing?.PlayedAt ?? DateTimeOffset.UtcNow : null;
        var archived = completed && existing?.Archived == true;

        var state = new EpisodeState(
            episodeId, userId, episodeId, showId, positionSeconds, completed, DateTimeOffset.UtcNow, deviceId,
            PlayedAt: playedAt, Archived: archived);

        await UpsertStateAsync(state, cancellationToken);
        return state;
    }

    // Used only by the unlistened-episode-limit enforcement job (#98) — distinct from
    // UpdateStateAsync so a manual "mark as played" (always AutoPlayed = false) can never be
    // confused with an automatic one, and so the enforcement job doesn't need to thread a
    // positionSeconds/completed pair through that a user-driven update path requires.
    public async Task MarkAutoPlayedAsync(
        string userId, IReadOnlyList<(string EpisodeId, string ShowId)> episodes, CancellationToken cancellationToken)
    {
        foreach (var (episodeId, showId) in episodes)
        {
            var state = new EpisodeState(
                episodeId, userId, episodeId, showId, PositionSeconds: 0, Completed: true, DateTimeOffset.UtcNow,
                DeviceId: null, AutoPlayed: true, PlayedAt: DateTimeOffset.UtcNow);
            await UpsertStateAsync(state, cancellationToken);
        }
    }

    // Used only by the auto-archive enforcement job (#187) — reads every state for a show
    // rather than filtering client-side after QueryAllStatesAsync so enforcement on a show with
    // many episodes doesn't have to pull every other show's states for this user too.
    public async Task<IReadOnlyList<EpisodeState>> GetShowStatesAsync(
        string userId, string showId, CancellationToken cancellationToken)
    {
        var results = new List<EpisodeState>();
        var queryDefinition = new QueryDefinition("SELECT * FROM c WHERE c.ShowId = @showId")
            .WithParameter("@showId", showId);
        using var iterator = episodeStatesContainer.GetItemQueryIterator<EpisodeState>(
            queryDefinition,
            requestOptions: new QueryRequestOptions { PartitionKey = new PartitionKey(userId) });

        while (iterator.HasMoreResults)
        {
            var page = await iterator.ReadNextAsync(cancellationToken);
            results.AddRange(page);
        }

        return results;
    }

    public async Task<IReadOnlyList<string>> GetInProgressShowIdsAsync(string userId, CancellationToken cancellationToken)
    {
        var showIds = new HashSet<string>(StringComparer.Ordinal);
        var queryDefinition = new QueryDefinition(
            "SELECT DISTINCT VALUE c.ShowId FROM c WHERE c.Completed = false AND c.PositionSeconds > 0");
        using var iterator = episodeStatesContainer.GetItemQueryIterator<string>(
            queryDefinition,
            requestOptions: new QueryRequestOptions { PartitionKey = new PartitionKey(userId) });

        while (iterator.HasMoreResults)
        {
            var page = await iterator.ReadNextAsync(cancellationToken);
            foreach (var showId in page)
            {
                if (!string.IsNullOrEmpty(showId))
                {
                    showIds.Add(showId);
                }
            }
        }

        return showIds.ToList();
    }

    // Used only by the auto-archive enforcement job (#187). Callers pass the already-fetched
    // EpisodeState records (e.g. from GetShowStatesAsync) rather than IDs so this doesn't re-read
    // each one via a point read on top of the caller's own query.
    public async Task SetArchivedAsync(
        string userId, IReadOnlyList<EpisodeState> states, bool archived, CancellationToken cancellationToken)
    {
        foreach (var existing in states)
        {
            if (existing.Archived == archived)
            {
                continue;
            }

            var updated = existing with { Archived = archived, UpdatedAt = DateTimeOffset.UtcNow };
            await UpsertStateAsync(updated, cancellationToken);
        }
    }

    public async Task<SyncEpisodesResult> SyncAsync(
        string userId,
        string deviceId,
        DateTimeOffset lastSyncedAt,
        string localHash,
        IReadOnlyList<EpisodeStateChange> changes,
        CancellationToken cancellationToken)
    {
        var result = await _reconciler.ReconcileAsync(
            userId,
            lastSyncedAt,
            localHash,
            changes,
            getChangeId: change => change.EpisodeId,
            getChangeUpdatedAt: change => change.UpdatedAt,
            buildAcceptedState: (change, stored) =>
            {
                // Mirrors UpdateStateAsync's PlayedAt/Archived handling — a sync push (e.g. from
                // iOS, whose only write path to episode state is this endpoint) must preserve or
                // clear those fields the same way a direct state PUT does, otherwise pushing an
                // already-played/archived episode's state (e.g. a later position touch) would
                // silently wipe PlayedAt and un-archive it.
                DateTimeOffset? playedAt = change.Completed ? stored?.PlayedAt ?? DateTimeOffset.UtcNow : null;
                var archived = change.Completed && stored?.Archived == true;
                return new EpisodeState(
                    change.EpisodeId,
                    userId,
                    change.EpisodeId,
                    change.ShowId,
                    change.PositionSeconds,
                    change.Completed,
                    DateTimeOffset.UtcNow,
                    deviceId,
                    PlayedAt: playedAt,
                    Archived: archived);
            },
            readStoredAsync: (episodeId, ct) => ReadStateAsync(userId, episodeId, ct),
            upsertAsync: UpsertStateAsync,
            queryAllAsync: ct => QueryAllStatesAsync(userId, ct),
            cancellationToken);

        return new SyncEpisodesResult(result.ServerChanges, result.SyncedAt, result.Hash);
    }

    private async Task<EpisodeState?> ReadStateAsync(string userId, string episodeId, CancellationToken cancellationToken)
    {
        try
        {
            var response = await episodeStatesContainer.ReadItemAsync<EpisodeState>(
                episodeId, new PartitionKey(userId), cancellationToken: cancellationToken);
            return response.Resource;
        }
        catch (CosmosException ex) when (ex.StatusCode == HttpStatusCode.NotFound)
        {
            return null;
        }
    }

    private async Task<IReadOnlyList<EpisodeState>> QueryAllStatesAsync(string userId, CancellationToken cancellationToken)
    {
        var results = new List<EpisodeState>();
        using var iterator = episodeStatesContainer.GetItemQueryIterator<EpisodeState>(
            new QueryDefinition("SELECT * FROM c"),
            requestOptions: new QueryRequestOptions { PartitionKey = new PartitionKey(userId) });

        while (iterator.HasMoreResults)
        {
            var page = await iterator.ReadNextAsync(cancellationToken);
            results.AddRange(page);
        }

        return results;
    }

    private Task UpsertStateAsync(EpisodeState state, CancellationToken cancellationToken) =>
        episodeStatesContainer.UpsertItemAsync(
            state, new PartitionKey(state.UserId), cancellationToken: cancellationToken);
}
