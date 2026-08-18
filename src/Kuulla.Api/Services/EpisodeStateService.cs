using System.Net;
using System.Security.Cryptography;
using System.Text;
using Kuulla.Api.Models;
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

    // The sync summary is only useful for as long as a device might plausibly still hold the
    // hash it's compared against — an inactive device that never comes back shouldn't keep its
    // user's summary cached in Redis forever.
    private static readonly TimeSpan SyncSummaryTtl = TimeSpan.FromDays(30);

    private static string HotStateKey(string userId, string episodeId) => $"{HotStateKeyPrefix}{userId}:{episodeId}";

    private static string SyncSummaryKey(string userId) => $"sync:episodes:{userId}";

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
        await RecomputeAndCacheSyncSummaryAsync(userId, cancellationToken);

        return state;
    }

    public async Task<SyncEpisodesResult> SyncAsync(
        string userId,
        string deviceId,
        DateTimeOffset lastSyncedAt,
        string localHash,
        IReadOnlyList<EpisodeStateChange> changes,
        CancellationToken cancellationToken)
    {
        // Fast path (docs/sync-conventions.md): nothing to push and the client's hash already
        // matches the server's — skip the reconciliation query entirely.
        if (changes.Count == 0)
        {
            var summary = await GetOrComputeSyncSummaryAsync(userId, cancellationToken);
            if (summary.Hash == localHash)
            {
                return new SyncEpisodesResult([], DateTimeOffset.UtcNow, summary.Hash);
            }
        }

        var storedStates = await Task.WhenAll(
            changes.Select(change => ReadStateAsync(userId, change.EpisodeId, cancellationToken)));

        var accepted = new List<EpisodeState>();
        for (var i = 0; i < changes.Count; i++)
        {
            var change = changes[i];
            var stored = storedStates[i];
            if (stored is not null && stored.UpdatedAt >= change.UpdatedAt)
            {
                // Stored record wins — client's write is discarded (its version is stale).
                continue;
            }

            accepted.Add(new EpisodeState(
                change.EpisodeId,
                userId,
                change.EpisodeId,
                change.ShowId,
                change.PositionSeconds,
                change.Completed,
                DateTimeOffset.UtcNow,
                deviceId));
        }

        await Task.WhenAll(accepted.Select(state => UpsertStateAsync(state, cancellationToken)));
        var acceptedEpisodeIds = accepted.Select(s => s.EpisodeId).ToHashSet();

        var allStates = await QueryAllStatesAsync(userId, cancellationToken);

        // Delta: everything newer than the client's last sync that it doesn't already hold the
        // winning version of (records it just pushed and had accepted above).
        var serverChanges = allStates
            .Where(s => s.UpdatedAt > lastSyncedAt && !acceptedEpisodeIds.Contains(s.EpisodeId))
            .ToList();

        var newSummary = ComputeSummary(allStates);
        await CacheSyncSummaryAsync(userId, newSummary, cancellationToken);

        return new SyncEpisodesResult(serverChanges, DateTimeOffset.UtcNow, newSummary.Hash);
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

    private async Task<SyncSummary> GetOrComputeSyncSummaryAsync(string userId, CancellationToken cancellationToken)
    {
        var db = redis.GetDatabase();
        var cached = await db.StringGetAsync(SyncSummaryKey(userId));
        if (cached.HasValue)
        {
            return JsonConvert.DeserializeObject<SyncSummary>((string)cached!)!;
        }

        return await RecomputeAndCacheSyncSummaryAsync(userId, cancellationToken);
    }

    private async Task<SyncSummary> RecomputeAndCacheSyncSummaryAsync(string userId, CancellationToken cancellationToken)
    {
        var allStates = await QueryAllStatesAsync(userId, cancellationToken);
        var summary = ComputeSummary(allStates);
        await CacheSyncSummaryAsync(userId, summary, cancellationToken);
        return summary;
    }

    private async Task CacheSyncSummaryAsync(string userId, SyncSummary summary, CancellationToken cancellationToken)
    {
        var db = redis.GetDatabase();
        await db.StringSetAsync(SyncSummaryKey(userId), JsonConvert.SerializeObject(summary), SyncSummaryTtl);
    }

    // docs/sync-conventions.md: hash = SHA-256 over the sorted set of "{recordId}:{updatedAt}"
    // pairs; updatedAt = max updatedAt across the collection (DateTimeOffset.MinValue when empty,
    // matching an always-caught-up client with nothing to sync).
    private static SyncSummary ComputeSummary(IReadOnlyList<EpisodeState> states)
    {
        var pairs = states
            .Select(s => $"{s.EpisodeId}:{s.UpdatedAt:O}")
            .OrderBy(pair => pair, StringComparer.Ordinal)
            .ToArray();

        var joined = string.Join("\n", pairs);
        var hashBytes = SHA256.HashData(Encoding.UTF8.GetBytes(joined));
        var hash = Convert.ToHexString(hashBytes).ToLowerInvariant();

        var maxUpdatedAt = states.Count > 0 ? states.Max(s => s.UpdatedAt) : DateTimeOffset.MinValue;
        return new SyncSummary(hash, maxUpdatedAt);
    }
}
