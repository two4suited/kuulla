using System.Net;
using Kuulla.Api.Models;
using Kuulla.Api.Services.Sync;
using Microsoft.Azure.Cosmos;
using Microsoft.Extensions.DependencyInjection;
using StackExchange.Redis;

namespace Kuulla.Api.Services;

public class PlaylistService(
    [FromKeyedServices("playlists")] Container playlistsContainer,
    IEpisodeService episodeService,
    IShowService showService,
    IConnectionMultiplexer redis) : IPlaylistService
{
    private readonly SyncSummaryCache<Playlist> _syncSummaryCache = new(redis, "playlists");

    // Lazy for the same CS0236 reason as EpisodeStateService.Reconciler — a primary-constructor
    // field initializer can't reference _syncSummaryCache before the constructor body runs.
    private SyncReconciler<Playlist, PlaylistChange>? _reconciler;
    private SyncReconciler<Playlist, PlaylistChange> Reconciler => _reconciler ??= new(_syncSummaryCache);

    public Task<IReadOnlyList<Playlist>> GetPlaylistsAsync(string userId, CancellationToken cancellationToken) =>
        QueryAllAsync(userId, cancellationToken);

    public async Task<Playlist> CreatePlaylistAsync(string userId, string name, CancellationToken cancellationToken)
    {
        var playlist = new Playlist(
            Guid.NewGuid().ToString(), userId, name, PlaylistType.Manual, [], DateTimeOffset.UtcNow, DateTimeOffset.UtcNow);

        await UpsertAsync(playlist, cancellationToken);
        await RecomputeSummaryAsync(userId, cancellationToken);
        return playlist;
    }

    public async Task<PlaylistDetail?> GetPlaylistDetailAsync(string userId, string id, CancellationToken cancellationToken)
    {
        var playlist = await ReadAsync(userId, id, cancellationToken);
        if (playlist is null)
        {
            return null;
        }

        // Resolve each distinct show once (not once per item) — a playlist with many episodes
        // from the same show shouldn't re-fetch that show's artwork per item.
        var showIds = playlist.Items.Select(item => item.ShowId).Distinct().ToList();
        var shows = await Task.WhenAll(showIds.Select(async showId =>
            (showId, show: await showService.GetByIdAsync(showId, cancellationToken))));
        var showsById = shows.ToDictionary(x => x.showId, x => x.show);

        var items = await Task.WhenAll(playlist.Items.Select(async item =>
        {
            var episode = await episodeService.GetEpisodeAsync(item.ShowId, item.EpisodeId, cancellationToken);
            showsById.TryGetValue(item.ShowId, out var show);
            return new PlaylistItemDetail(
                item.EpisodeId, item.ShowId, episode?.Title, show?.ArtworkUrl, item.AddedAt, item.Order);
        }));

        return new PlaylistDetail(playlist.Id, playlist.Name, playlist.Type, items, playlist.CreatedAt, playlist.UpdatedAt);
    }

    public async Task<Playlist?> RenamePlaylistAsync(string userId, string id, string name, CancellationToken cancellationToken)
    {
        var playlist = await ReadAsync(userId, id, cancellationToken);
        if (playlist is null)
        {
            return null;
        }

        var updated = playlist with { Name = name, UpdatedAt = DateTimeOffset.UtcNow };
        await UpsertAsync(updated, cancellationToken);
        await RecomputeSummaryAsync(userId, cancellationToken);
        return updated;
    }

    public async Task DeletePlaylistAsync(string userId, string id, CancellationToken cancellationToken)
    {
        try
        {
            await playlistsContainer.DeleteItemAsync<Playlist>(id, new PartitionKey(userId), cancellationToken: cancellationToken);
        }
        catch (CosmosException ex) when (ex.StatusCode == HttpStatusCode.NotFound)
        {
            // Already deleted — idempotent no-op.
        }

        // Note: the sync reconciler (SyncReconciler<TState,TChange>) has no tombstone concept —
        // it only ever returns "records changed since lastSyncedAt", so a deletion here won't be
        // propagated to other devices via POST /api/sync/playlists. That's a pre-existing gap in
        // the shared framework (EpisodeState has no delete operation to have surfaced it before
        // now), not something this issue's scope covers fixing.
        await RecomputeSummaryAsync(userId, cancellationToken);
    }

    public async Task<Playlist?> AddItemAsync(
        string userId, string id, string episodeId, string showId, CancellationToken cancellationToken)
    {
        var playlist = await ReadAsync(userId, id, cancellationToken);
        if (playlist is null)
        {
            return null;
        }

        if (playlist.Items.Any(item => item.EpisodeId == episodeId))
        {
            return playlist;
        }

        var maxOrder = playlist.Items.Count > 0
            ? playlist.Items.Select(item => item.Order).OrderByDescending(o => o, StringComparer.Ordinal).First()
            : null;
        var order = PlaylistRankGenerator.Between(maxOrder, after: null);

        var items = playlist.Items
            .Append(new PlaylistItem(episodeId, showId, DateTimeOffset.UtcNow, order))
            .OrderBy(item => item.Order, StringComparer.Ordinal)
            .ToList();

        var updated = playlist with { Items = items, UpdatedAt = DateTimeOffset.UtcNow };
        await UpsertAsync(updated, cancellationToken);
        await RecomputeSummaryAsync(userId, cancellationToken);
        return updated;
    }

    public async Task<Playlist?> RemoveItemAsync(string userId, string id, string episodeId, CancellationToken cancellationToken)
    {
        var playlist = await ReadAsync(userId, id, cancellationToken);
        if (playlist is null)
        {
            return null;
        }

        if (playlist.Items.All(item => item.EpisodeId != episodeId))
        {
            return playlist;
        }

        var items = playlist.Items.Where(item => item.EpisodeId != episodeId).ToList();
        var updated = playlist with { Items = items, UpdatedAt = DateTimeOffset.UtcNow };
        await UpsertAsync(updated, cancellationToken);
        await RecomputeSummaryAsync(userId, cancellationToken);
        return updated;
    }

    public async Task<Playlist?> ReorderItemAsync(
        string userId,
        string id,
        string episodeId,
        string? beforeEpisodeId,
        string? afterEpisodeId,
        CancellationToken cancellationToken)
    {
        var playlist = await ReadAsync(userId, id, cancellationToken);
        if (playlist is null)
        {
            return null;
        }

        if (playlist.Items.All(item => item.EpisodeId != episodeId))
        {
            return playlist;
        }

        // A neighbor id that doesn't resolve to an item in this playlist (stale client state, a
        // concurrent removal, or a bad request) must be rejected rather than silently treated as
        // "no bound" — that would compute a rank based on the wrong neighbor and misplace the
        // item without any error surfacing to the caller.
        string? ResolveNeighborOrder(string? neighborEpisodeId)
        {
            if (neighborEpisodeId is null)
            {
                return null;
            }

            var neighbor = playlist.Items.FirstOrDefault(item => item.EpisodeId == neighborEpisodeId);
            return neighbor is not null
                ? neighbor.Order
                : throw new ArgumentException($"'{neighborEpisodeId}' is not an item in this playlist.");
        }

        var beforeOrder = ResolveNeighborOrder(beforeEpisodeId);
        var afterOrder = ResolveNeighborOrder(afterEpisodeId);

        var newOrder = PlaylistRankGenerator.Between(beforeOrder, afterOrder);
        var items = playlist.Items
            .Select(item => item.EpisodeId == episodeId ? item with { Order = newOrder } : item)
            .OrderBy(item => item.Order, StringComparer.Ordinal)
            .ToList();

        var updated = playlist with { Items = items, UpdatedAt = DateTimeOffset.UtcNow };
        await UpsertAsync(updated, cancellationToken);
        await RecomputeSummaryAsync(userId, cancellationToken);
        return updated;
    }

    public async Task<SyncPlaylistsResult> SyncAsync(
        string userId,
        string deviceId,
        DateTimeOffset lastSyncedAt,
        string localHash,
        IReadOnlyList<PlaylistChange> changes,
        CancellationToken cancellationToken)
    {
        var result = await Reconciler.ReconcileAsync(
            userId,
            lastSyncedAt,
            localHash,
            changes,
            getChangeId: change => change.Id,
            getChangeUpdatedAt: change => change.UpdatedAt,
            buildAcceptedState: change => new Playlist(
                change.Id,
                userId,
                change.Name,
                change.Type,
                change.Items,
                change.CreatedAt,
                DateTimeOffset.UtcNow,
                deviceId),
            readStoredAsync: (id, ct) => ReadAsync(userId, id, ct),
            upsertAsync: UpsertAsync,
            queryAllAsync: ct => QueryAllAsync(userId, ct),
            cancellationToken);

        return new SyncPlaylistsResult(result.ServerChanges, result.SyncedAt, result.Hash);
    }

    private async Task<Playlist?> ReadAsync(string userId, string id, CancellationToken cancellationToken)
    {
        try
        {
            var response = await playlistsContainer.ReadItemAsync<Playlist>(
                id, new PartitionKey(userId), cancellationToken: cancellationToken);
            return response.Resource;
        }
        catch (CosmosException ex) when (ex.StatusCode == HttpStatusCode.NotFound)
        {
            return null;
        }
    }

    private async Task<IReadOnlyList<Playlist>> QueryAllAsync(string userId, CancellationToken cancellationToken)
    {
        var results = new List<Playlist>();
        using var iterator = playlistsContainer.GetItemQueryIterator<Playlist>(
            new QueryDefinition("SELECT * FROM c"),
            requestOptions: new QueryRequestOptions { PartitionKey = new PartitionKey(userId) });

        while (iterator.HasMoreResults)
        {
            var page = await iterator.ReadNextAsync(cancellationToken);
            results.AddRange(page);
        }

        return results;
    }

    private async Task UpsertAsync(Playlist playlist, CancellationToken cancellationToken)
    {
        await playlistsContainer.UpsertItemAsync(
            playlist, new PartitionKey(playlist.UserId), cancellationToken: cancellationToken);
    }

    private async Task RecomputeSummaryAsync(string userId, CancellationToken cancellationToken)
    {
        var all = await QueryAllAsync(userId, cancellationToken);
        await _syncSummaryCache.SetAsync(userId, SyncSummaryCache<Playlist>.Compute(all), cancellationToken);
    }
}
