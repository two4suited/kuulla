using System.Net;
using Kuulla.Api.Models;
using Kuulla.Api.Services.Sync;
using Microsoft.Azure.Cosmos;
using Microsoft.Extensions.DependencyInjection;
using Newtonsoft.Json;
using StackExchange.Redis;

namespace Kuulla.Api.Services;

public class EpisodeStateService(
    [FromKeyedServices("episodestates")] Container episodeStatesContainer,
    IConnectionMultiplexer redis) : IEpisodeStateService
{
    // Hot playback-position cache: a client polls/pushes position far more often than it runs a
    // full sync, so this cache exists to keep that read/write path off Cosmos. Cosmos remains the
    // source of truth (and what the sync summary hash is computed from), so a cache miss or
    // eviction is harmless — GetStateAsync falls back to Cosmos and repopulates it.
    private const string HotStateKeyPrefix = "episodestate:";
    private static readonly TimeSpan HotStateTtl = TimeSpan.FromHours(24);

    private readonly SyncSummaryCache<EpisodeState> _syncSummaryCache = new(redis, "episodes");

    // A field initializer can't reference _syncSummaryCache (CS0236: no referencing other
    // instance fields before the constructor body runs), so the reconciler is built lazily on
    // first use instead — that keeps this class on a primary constructor while still sharing the
    // one _syncSummaryCache instance rather than standing up a second, separately-configured one.
    private SyncReconciler<EpisodeState, EpisodeStateChange>? _reconciler;
    private SyncReconciler<EpisodeState, EpisodeStateChange> Reconciler => _reconciler ??= new(_syncSummaryCache);

    private static string HotStateKey(string userId, string episodeId) => $"{HotStateKeyPrefix}{userId}:{episodeId}";

    public async Task<EpisodeState?> GetStateAsync(string userId, string episodeId, CancellationToken cancellationToken)
    {
        var db = redis.GetDatabase();
        var cached = await db.StringGetAsync(HotStateKey(userId, episodeId));
        if (cached.HasValue)
        {
            return JsonConvert.DeserializeObject<EpisodeState>((string)cached!);
        }

        var state = await ReadStateAsync(userId, episodeId, cancellationToken);
        if (state is not null)
        {
            await CacheHotStateAsync(state, cancellationToken);
        }

        return state;
    }

    // Lets a page render N episodes' state with one HTTP round trip instead of N (e.g. ShowDetail's
    // auto-played indicator) — still one GetStateAsync per id under the hood (each still benefits
    // from the hot Redis cache), just fanned out in parallel behind a single request.
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
        var state = new EpisodeState(
            episodeId, userId, episodeId, showId, positionSeconds, completed, DateTimeOffset.UtcNow, deviceId);

        await UpsertStateAsync(state, cancellationToken);
        var allStates = await QueryAllStatesAsync(userId, cancellationToken);
        await _syncSummaryCache.SetAsync(userId, SyncSummaryCache<EpisodeState>.Compute(allStates), cancellationToken);

        return state;
    }

    // Used only by the unlistened-episode-limit enforcement job (#98) — distinct from
    // UpdateStateAsync so a manual "mark as played" (always AutoPlayed = false) can never be
    // confused with an automatic one, and so the enforcement job doesn't need to thread a
    // positionSeconds/completed pair through that a user-driven update path requires.
    // Batched (one call per enforcement run, not per episode) so the sync summary is recomputed
    // once instead of once per marked episode — a back catalog with hundreds of episodes beyond
    // the limit would otherwise trigger hundreds of redundant QueryAllStatesAsync/cache-set calls.
    public async Task MarkAutoPlayedAsync(
        string userId, IReadOnlyList<(string EpisodeId, string ShowId)> episodes, CancellationToken cancellationToken)
    {
        if (episodes.Count == 0)
        {
            return;
        }

        foreach (var (episodeId, showId) in episodes)
        {
            var state = new EpisodeState(
                episodeId, userId, episodeId, showId, PositionSeconds: 0, Completed: true, DateTimeOffset.UtcNow,
                DeviceId: null, AutoPlayed: true);
            await UpsertStateAsync(state, cancellationToken);
        }

        var allStates = await QueryAllStatesAsync(userId, cancellationToken);
        await _syncSummaryCache.SetAsync(userId, SyncSummaryCache<EpisodeState>.Compute(allStates), cancellationToken);
    }

    public async Task<SyncEpisodesResult> SyncAsync(
        string userId,
        string deviceId,
        DateTimeOffset lastSyncedAt,
        string localHash,
        IReadOnlyList<EpisodeStateChange> changes,
        CancellationToken cancellationToken)
    {
        var result = await Reconciler.ReconcileAsync(
            userId,
            lastSyncedAt,
            localHash,
            changes,
            getChangeId: change => change.EpisodeId,
            getChangeUpdatedAt: change => change.UpdatedAt,
            buildAcceptedState: change => new EpisodeState(
                change.EpisodeId,
                userId,
                change.EpisodeId,
                change.ShowId,
                change.PositionSeconds,
                change.Completed,
                DateTimeOffset.UtcNow,
                deviceId),
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

    private async Task UpsertStateAsync(EpisodeState state, CancellationToken cancellationToken)
    {
        await episodeStatesContainer.UpsertItemAsync(
            state, new PartitionKey(state.UserId), cancellationToken: cancellationToken);
        await CacheHotStateAsync(state, cancellationToken);
    }

    private async Task CacheHotStateAsync(EpisodeState state, CancellationToken cancellationToken)
    {
        var db = redis.GetDatabase();
        await db.StringSetAsync(
            HotStateKey(state.UserId, state.EpisodeId), JsonConvert.SerializeObject(state), HotStateTtl);
    }
}
