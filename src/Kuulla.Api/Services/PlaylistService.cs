using System.Net;
using Kuulla.Api.Models;
using Kuulla.Api.Services.Sync;
using Microsoft.Azure.Cosmos;
using Microsoft.Extensions.DependencyInjection;

namespace Kuulla.Api.Services;

public class PlaylistService(
    [FromKeyedServices("playlists")] Container playlistsContainer,
    IEpisodeService episodeService,
    IEpisodeStateService episodeStateService,
    IShowService showService) : IPlaylistService
{
    private readonly SyncReconciler<Playlist, PlaylistChange> _reconciler = new();

    public Task<IReadOnlyList<Playlist>> GetPlaylistsAsync(string userId, CancellationToken cancellationToken) =>
        QueryAllAsync(userId, cancellationToken);

    public async Task<Playlist> CreatePlaylistAsync(
        string userId, string name, string? icon, string? accentColor, CancellationToken cancellationToken)
    {
        var now = DateTimeOffset.UtcNow;
        var playlist = new Playlist(
            Guid.NewGuid().ToString(), userId, name, PlaylistType.Manual, [], now, now,
            Icon: icon, AccentColor: accentColor);

        await UpsertAsync(playlist, cancellationToken);
        return playlist;
    }

    public async Task<Playlist> CreateDynamicPlaylistAsync(
        string userId, string name, DynamicPlaylistConfig config, string? icon, string? accentColor, CancellationToken cancellationToken)
    {
        var now = DateTimeOffset.UtcNow;
        var playlist = new Playlist(
            Guid.NewGuid().ToString(), userId, name, PlaylistType.Dynamic, [], now, now,
            DynamicConfig: config, Icon: icon, AccentColor: accentColor);

        var items = await ComputeDynamicItemsAsync(userId, config, cancellationToken);
        var populated = playlist with { Items = items };
        await UpsertAsync(populated, cancellationToken);
        return populated;
    }

    public async Task<Playlist?> UpdateDynamicPlaylistConfigAsync(
        string userId, string id, DynamicPlaylistConfig config, CancellationToken cancellationToken)
    {
        var playlist = await ReadAsync(userId, id, cancellationToken);
        if (playlist is null || playlist.Type != PlaylistType.Dynamic)
        {
            return null;
        }

        var items = await ComputeDynamicItemsAsync(userId, config, cancellationToken);
        var updated = playlist with { DynamicConfig = config, Items = items, UpdatedAt = DateTimeOffset.UtcNow };
        await UpsertAsync(updated, cancellationToken);
        return updated;
    }

    public async Task<Playlist?> RecomputeDynamicPlaylistAsync(string userId, string id, CancellationToken cancellationToken)
    {
        var playlist = await ReadAsync(userId, id, cancellationToken);
        if (playlist is not { Type: PlaylistType.Dynamic, DynamicConfig: not null })
        {
            return null;
        }

        var items = await ComputeDynamicItemsAsync(userId, playlist.DynamicConfig, cancellationToken);
        var updated = playlist with { Items = items, UpdatedAt = DateTimeOffset.UtcNow };
        await UpsertAsync(updated, cancellationToken);
        return updated;
    }

    // Shared by CreateDynamicPlaylistAsync/UpdateDynamicPlaylistConfigAsync/
    // RecomputeDynamicPlaylistAsync — see IPlaylistService.RecomputeDynamicPlaylistAsync for why
    // this full-rebuild logic is factored out as its own method rather than inlined.
    // Playlists are stored as a single Cosmos document with Items embedded inline (see Playlist's
    // doc comment), which caps out at Cosmos's 2MB item size limit. MaxEpisodes is user-facing and
    // optional (null = "no limit the user asked for"), but an unbounded playlist over several
    // high-volume shows could still blow past that document limit and fail to save.
    // PlaylistRankGenerator.UnboundedSafetyCap is the ceiling applied when the user didn't set
    // one — shared with EpisodeService's incremental insert path (#112) so both the full-rebuild
    // and per-episode-insert paths enforce the same cap.
    // A dynamic playlist tracks what's left to listen to, not a show's whole back catalogue, so
    // episodes the user has already finished (or that unlistened-limit enforcement auto-marked
    // played, #97) are filtered out before ordering/capping — without this, MaxEpisodes fills up
    // with played episodes and the "N episodes total" count dwarfs the handful actually left to
    // hear (#433). An in-progress episode (a saved position but not Completed) is deliberately
    // kept so a partially-heard episode isn't dropped before it's finished.
    private async Task<IReadOnlyList<PlaylistItem>> ComputeDynamicItemsAsync(
        string userId, DynamicPlaylistConfig config, CancellationToken cancellationToken)
    {
        var showRank = config.PriorityList
            .Select((showId, index) => (showId, index))
            .ToDictionary(x => x.showId, x => x.index);

        // Per show: its episodes and the user's play state for that show, fetched together. State
        // is a single-partition query per show (GetShowStatesAsync) rather than a point read per
        // episode — an unbounded playlist over large back catalogues would otherwise fan out
        // thousands of point reads on every recompute.
        var perShow = await Task.WhenAll(config.ShowIds.Select(async showId =>
        {
            var episodesTask = episodeService.GetAllEpisodesOrderedAsync(showId, cancellationToken);
            var statesTask = episodeStateService.GetShowStatesAsync(userId, showId, cancellationToken);
            await Task.WhenAll(episodesTask, statesTask);
            return (showId, episodes: episodesTask.Result, states: statesTask.Result);
        }));

        var playedEpisodeIds = perShow
            .SelectMany(x => x.states)
            .Where(state => state.Completed || state.AutoPlayed)
            .Select(state => state.EpisodeId)
            .ToHashSet();

        var addedAt = DateTimeOffset.UtcNow;

        // MaxEpisodes is optional — no explicit cap still applies PlaylistRankGenerator.
        // UnboundedSafetyCap rather than truly no limit.
        var ordered = perShow
            .OrderBy(x => showRank.TryGetValue(x.showId, out var rank) ? rank : int.MaxValue)
            .SelectMany(x => x.episodes.Select(episode => (x.showId, episode)))
            .Where(x => !playedEpisodeIds.Contains(x.episode.Id))
            .Take(config.MaxEpisodes ?? PlaylistRankGenerator.UnboundedSafetyCap);

        var items = new List<PlaylistItem>();
        string? previousOrder = null;
        foreach (var (showId, episode) in ordered)
        {
            var order = PlaylistRankGenerator.Between(previousOrder, null);
            items.Add(new PlaylistItem(episode.Id, showId, addedAt, order));
            previousOrder = order;
        }

        return items;
    }

    // Compares two Items lists by their (EpisodeId, ShowId) sequence only — deliberately ignoring
    // Order and AddedAt. ComputeDynamicItemsAsync stamps a fresh AddedAt on every call and could in
    // principle re-derive different rank strings, so comparing those fields would report a spurious
    // change (and a needless write) even when the actual episode membership and ordering are
    // identical.
    private static bool SameEpisodes(IReadOnlyList<PlaylistItem> current, IReadOnlyList<PlaylistItem> recomputed)
    {
        if (current.Count != recomputed.Count)
        {
            return false;
        }

        for (var i = 0; i < current.Count; i++)
        {
            if (current[i].EpisodeId != recomputed[i].EpisodeId || current[i].ShowId != recomputed[i].ShowId)
            {
                return false;
            }
        }

        return true;
    }

    public async Task<PlaylistDetail?> GetPlaylistDetailAsync(string userId, string id, CancellationToken cancellationToken)
    {
        var playlist = await ReadAsync(userId, id, cancellationToken);
        if (playlist is null)
        {
            return null;
        }

        // A dynamic playlist's stored Items are only as fresh as its last create / config-save /
        // explicit recompute. The #112 auto-insert hook only ever *adds* newly-published episodes;
        // nothing prunes an episode once the user finishes it, so the stored list (and the
        // "N episodes total" count built from it) drifts to include played episodes over time
        // (follow-up to #433, which only fixed freshly-computed playlists). Rebuild from current
        // play state on read, and persist the result only when the episode set actually changed —
        // so the next reader, the sync feed, and iOS all converge on the pruned list without
        // waiting for an explicit recompute, while an unchanged playlist doesn't churn its
        // UpdatedAt / sync hash on every page view.
        if (playlist is { Type: PlaylistType.Dynamic, DynamicConfig: { } config })
        {
            var fresh = await ComputeDynamicItemsAsync(userId, config, cancellationToken);
            if (!SameEpisodes(playlist.Items, fresh))
            {
                playlist = playlist with { Items = fresh, UpdatedAt = DateTimeOffset.UtcNow };
                await UpsertAsync(playlist, cancellationToken);
            }
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

        return new PlaylistDetail(
            playlist.Id, playlist.Name, playlist.Type, items, playlist.CreatedAt, playlist.UpdatedAt,
            playlist.DynamicConfig, playlist.Icon, playlist.AccentColor);
    }

    public async Task<Playlist?> RenamePlaylistAsync(
        string userId, string id, string name, string? icon, string? accentColor, CancellationToken cancellationToken)
    {
        var playlist = await ReadAsync(userId, id, cancellationToken);
        if (playlist is null)
        {
            return null;
        }

        var updated = playlist with
        {
            Name = name,
            Icon = icon,
            AccentColor = accentColor,
            UpdatedAt = DateTimeOffset.UtcNow,
        };
        await UpsertAsync(updated, cancellationToken);
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
        var result = await _reconciler.ReconcileAsync(
            userId,
            lastSyncedAt,
            localHash,
            changes,
            getChangeId: change => change.Id,
            getChangeUpdatedAt: change => change.UpdatedAt,
            buildAcceptedState: (change, _) => new Playlist(
                change.Id,
                userId,
                change.Name,
                change.Type,
                change.Items,
                change.CreatedAt,
                DateTimeOffset.UtcNow,
                deviceId,
                change.DynamicConfig,
                change.Icon,
                change.AccentColor),
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
}
