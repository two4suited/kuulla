using Kuulla.Core.Services;
using System.Net;
using Kuulla.Core.Models;
using Kuulla.Core.Services.Sync;
using Microsoft.Azure.Cosmos;
using Microsoft.Extensions.DependencyInjection;

namespace Kuulla.Api.Services;

public class PlaylistService(
    [FromKeyedServices("playlists")] Container playlistsContainer,
    IEpisodeService episodeService,
    IEpisodeStateService episodeStateService,
    ISettingsService settingsService,
    IShowService showService) : IPlaylistService
{
    private readonly SyncReconciler<Playlist, PlaylistChange> _reconciler = new();

    // How long a deleted playlist's tombstone is retained before it's hard-deleted (#400). A
    // device that hasn't synced within this window and still holds the playlist will re-push it
    // on its next sync and resurrect it — the same staleness bound the reconciliation protocol
    // already assumes elsewhere (docs/sync-conventions.md). Kept in sync with any client-side
    // "drop sync state older than N days" logic.
    public static readonly TimeSpan TombstoneRetention = TimeSpan.FromDays(30);

    public async Task<IReadOnlyList<Playlist>> GetPlaylistsAsync(string userId, CancellationToken cancellationToken)
    {
        var all = await QueryAllAsync(userId, cancellationToken);
        var active = all.Where(p => !p.Deleted).ToList();

        // The list view's "N episodes" count comes straight from each Playlist's stored Items, so
        // it needs the same lazy prune GetPlaylistDetailAsync applies — otherwise a dynamic
        // playlist's list-level count keeps counting played episodes until its detail view happens
        // to be opened (#747).
        return await Task.WhenAll(active.Select(p => PruneDynamicPlaylistAsync(userId, p, cancellationToken)));
    }

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
        if (playlist is null or { Deleted: true } || playlist.Type != PlaylistType.Dynamic)
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
        if (playlist is not { Type: PlaylistType.Dynamic, DynamicConfig: not null, Deleted: false })
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
    // The show's effective unlistened-episode limit (#97) is also applied here: only the N
    // most-recent episodes of a show are eligible, matching what EnforceUnlistenedLimitAsync
    // would eventually auto-mark played on the next feed sweep. Without this, adding a show with
    // a large unplayed back catalogue to a dynamic playlist dumps the whole archive in before
    // enforcement has run. Episodes past the limit that already carry a state (in-progress, or a
    // manual "mark unplayed") are left in, exactly as the enforcement job leaves them alone.
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
            var limitTask = settingsService.GetEffectiveUnlistenedEpisodeCountAsync(userId, showId, cancellationToken);
            await Task.WhenAll(episodesTask, statesTask, limitTask);
            return (showId, episodes: episodesTask.Result, states: statesTask.Result, limit: limitTask.Result);
        }));

        var excludedEpisodeIds = new HashSet<string>();
        foreach (var show in perShow)
        {
            var episodeIdsWithState = show.states.Select(state => state.EpisodeId).ToHashSet();

            foreach (var state in show.states.Where(state => state.Completed || state.AutoPlayed))
            {
                excludedEpisodeIds.Add(state.EpisodeId);
            }

            // show.episodes is newest-first (GetAllEpisodesOrderedAsync). Everything past the
            // effective limit is dropped unless it already has a play state — see the doc comment.
            if (show.limit != UnlistenedEpisodeCount.Unlimited)
            {
                foreach (var episode in show.episodes.Skip((int)show.limit))
                {
                    if (!episodeIdsWithState.Contains(episode.Id))
                    {
                        excludedEpisodeIds.Add(episode.Id);
                    }
                }
            }
        }

        var addedAt = DateTimeOffset.UtcNow;

        // MaxEpisodes is optional — no explicit cap still applies PlaylistRankGenerator.
        // UnboundedSafetyCap rather than truly no limit.
        var ordered = perShow
            .OrderBy(x => showRank.TryGetValue(x.showId, out var rank) ? rank : int.MaxValue)
            .SelectMany(x => x.episodes.Select(episode => (x.showId, episode)))
            .Where(x => !excludedEpisodeIds.Contains(x.episode.Id))
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

    // A dynamic playlist's stored Items are only as fresh as its last create / config-save /
    // explicit recompute. The #112 auto-insert hook only ever *adds* newly-published episodes;
    // nothing prunes an episode once the user finishes it, so the stored list (and the
    // "N episodes total" count built from it) drifts to include played episodes over time
    // (follow-up to #433, which only fixed freshly-computed playlists). Rebuild from current
    // play state on read, and persist the result only when the episode set actually changed —
    // so the next reader, the sync feed, and iOS all converge on the pruned list without
    // waiting for an explicit recompute, while an unchanged playlist doesn't churn its
    // UpdatedAt / sync hash on every page view.
    // Best-effort: a throttled/unavailable Cosmos call in the recompute/persist should fall
    // back to serving the last-known list rather than 500ing the whole read, unlike a manual
    // playlist's read this branch never touches Cosmos beyond the initial ReadAsync in the caller.
    // iOS's auto-advance (#629) calls GetPlaylistDetailAsync on every natural finish
    // (PlaybackQueue.resolvePlayNextBehavior / begin(playlistId:)) — a 500 here reads as
    // "playlist gone" and clears the queue, silently stopping playback instead of advancing.
    // Only the known-transient status codes are swallowed — anything else (auth, a malformed
    // query) still surfaces as a 500.
    private async Task<Playlist> PruneDynamicPlaylistAsync(
        string userId, Playlist playlist, CancellationToken cancellationToken)
    {
        if (playlist is not { Type: PlaylistType.Dynamic, DynamicConfig: { } config })
        {
            return playlist;
        }

        try
        {
            var fresh = await ComputeDynamicItemsAsync(userId, config, cancellationToken);
            if (!SameEpisodes(playlist.Items, fresh))
            {
                var updated = playlist with { Items = fresh, UpdatedAt = DateTimeOffset.UtcNow };
                await UpsertAsync(updated, cancellationToken);
                return updated;
            }
        }
        catch (CosmosException ex) when (
            ex.StatusCode is HttpStatusCode.TooManyRequests or HttpStatusCode.ServiceUnavailable
                or HttpStatusCode.RequestTimeout)
        {
        }

        return playlist;
    }

    public async Task<PlaylistDetail?> GetPlaylistDetailAsync(string userId, string id, CancellationToken cancellationToken)
    {
        var playlist = await ReadAsync(userId, id, cancellationToken);
        if (playlist is null or { Deleted: true })
        {
            return null;
        }

        playlist = await PruneDynamicPlaylistAsync(userId, playlist, cancellationToken);

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
                item.EpisodeId, item.ShowId, episode?.Title, show?.ArtworkUrl, item.AddedAt, item.Order,
                episode?.Duration);
        }));

        return new PlaylistDetail(
            playlist.Id, playlist.Name, playlist.Type, items, playlist.CreatedAt, playlist.UpdatedAt,
            playlist.DynamicConfig, playlist.Icon, playlist.AccentColor, playlist.PlayNextBehavior);
    }

    public async Task<Playlist?> RenamePlaylistAsync(
        string userId, string id, string name, string? icon, string? accentColor, PlayNextBehavior? playNextBehavior,
        CancellationToken cancellationToken)
    {
        var playlist = await ReadAsync(userId, id, cancellationToken);
        if (playlist is null or { Deleted: true })
        {
            return null;
        }

        var updated = playlist with
        {
            Name = name,
            Icon = icon,
            AccentColor = accentColor,
            PlayNextBehavior = playNextBehavior,
            UpdatedAt = DateTimeOffset.UtcNow,
        };
        await UpsertAsync(updated, cancellationToken);
        return updated;
    }

    // Soft-delete: write a tombstone (Deleted = true, server-stamped UpdatedAt, Items dropped)
    // rather than hard-deleting the Cosmos item, so the deletion propagates to other devices
    // through POST /api/sync/playlists (#400). The reconciler returns the tombstone in the delta
    // and folds its moved UpdatedAt into the summary hash; clients apply it by removing their
    // local copy. The row is hard-deleted later, once it ages past TombstoneRetention
    // (QueryAllForSyncAsync). Idempotent — deleting an absent or already-tombstoned playlist is a
    // no-op that doesn't bump UpdatedAt again.
    public async Task DeletePlaylistAsync(string userId, string id, CancellationToken cancellationToken)
    {
        var existing = await ReadAsync(userId, id, cancellationToken);
        if (existing is null or { Deleted: true })
        {
            return;
        }

        var tombstone = existing with
        {
            Deleted = true,
            Items = [],
            DynamicConfig = null,
            UpdatedAt = DateTimeOffset.UtcNow,
        };
        await UpsertAsync(tombstone, cancellationToken);
    }

    public async Task<Playlist?> AddItemAsync(
        string userId, string id, string episodeId, string showId, CancellationToken cancellationToken)
    {
        var playlist = await ReadAsync(userId, id, cancellationToken);
        if (playlist is null or { Deleted: true })
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
        if (playlist is null or { Deleted: true })
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

    // Unsubscribe cleanup (#506): a `Subscription` delete used to leave everything created while
    // subscribed behind, so an episode from an unsubscribed show kept showing up in a playlist.
    // Sweep the user's playlists and pull the show out of each one — matching items from manual
    // playlists, and the show id from a dynamic playlist's config (then recompute its items from
    // what's left). Skip tombstoned playlists, and only write a playlist that actually referenced
    // the show so unaffected playlists don't churn their UpdatedAt / sync hash. This is a single
    // user's partition (a handful of playlists), so it runs inline on the unsubscribe request
    // rather than as a background sweep. `EpisodeState` is intentionally out of scope — see the
    // DELETE /api/subscriptions/{showId} endpoint for the keep-for-resubscribe rationale.
    public async Task RemoveShowAsync(string userId, string showId, CancellationToken cancellationToken)
    {
        var playlists = await QueryAllAsync(userId, cancellationToken);

        foreach (var playlist in playlists)
        {
            if (playlist.Deleted)
            {
                continue;
            }

            if (playlist is { Type: PlaylistType.Dynamic, DynamicConfig: { } config })
            {
                if (!config.ShowIds.Contains(showId) && !config.PriorityList.Contains(showId))
                {
                    continue;
                }

                var trimmedConfig = config with
                {
                    ShowIds = config.ShowIds.Where(id => id != showId).ToList(),
                    PriorityList = config.PriorityList.Where(id => id != showId).ToList(),
                };
                var recomputed = await ComputeDynamicItemsAsync(userId, trimmedConfig, cancellationToken);
                var updatedDynamic = playlist with
                {
                    DynamicConfig = trimmedConfig,
                    Items = recomputed,
                    UpdatedAt = DateTimeOffset.UtcNow,
                };
                await UpsertAsync(updatedDynamic, cancellationToken);
                continue;
            }

            if (playlist.Items.All(item => item.ShowId != showId))
            {
                continue;
            }

            var remaining = playlist.Items.Where(item => item.ShowId != showId).ToList();
            var updated = playlist with { Items = remaining, UpdatedAt = DateTimeOffset.UtcNow };
            await UpsertAsync(updated, cancellationToken);
        }
    }

    public async Task RemoveEpisodesFromManualPlaylistsAsync(
        string userId, IReadOnlyList<string> episodeIds, CancellationToken cancellationToken)
    {
        if (episodeIds.Count == 0)
        {
            return;
        }

        var episodeIdSet = episodeIds.ToHashSet();
        var playlists = await QueryAllAsync(userId, cancellationToken);

        foreach (var playlist in playlists)
        {
            if (playlist.Deleted || playlist.Type != PlaylistType.Manual)
            {
                continue;
            }

            if (playlist.Items.All(item => !episodeIdSet.Contains(item.EpisodeId)))
            {
                continue;
            }

            var remaining = playlist.Items.Where(item => !episodeIdSet.Contains(item.EpisodeId)).ToList();
            var updated = playlist with { Items = remaining, UpdatedAt = DateTimeOffset.UtcNow };
            await UpsertAsync(updated, cancellationToken);
        }
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
        if (playlist is null or { Deleted: true })
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
                change.AccentColor,
                change.PlayNextBehavior),
            readStoredAsync: (id, ct) => ReadAsync(userId, id, ct),
            upsertAsync: UpsertAsync,
            queryAllAsync: ct => QueryAllForSyncAsync(userId, ct),
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

    // The reconciler's query-all delegate: returns every row including live tombstones, so a
    // deletion still appears in the delta and the summary hash (#400). Tombstones past
    // TombstoneRetention are hard-deleted here and dropped from the result — this is the
    // domain's tombstone GC, run opportunistically on each sync rather than as a separate job.
    // A GC delete that races another writer (404/412) is ignored: the row is already gone or
    // will be re-evaluated next sweep.
    //
    // This is also the feed that populates each device's local PlaylistRecord store (#511) — the
    // "N episodes" count iOS shows in the playlist list comes straight from a synced dynamic
    // playlist's Items, so it needs the same lazy prune GetPlaylistDetailAsync applies, or the
    // list-level count keeps counting played episodes until the detail view happens to be opened
    // on some device (#747).
    private async Task<IReadOnlyList<Playlist>> QueryAllForSyncAsync(string userId, CancellationToken cancellationToken)
    {
        var all = await QueryAllAsync(userId, cancellationToken);
        all = await Task.WhenAll(all.Select(p => p.Deleted
            ? Task.FromResult(p)
            : PruneDynamicPlaylistAsync(userId, p, cancellationToken)));

        var cutoff = DateTimeOffset.UtcNow - TombstoneRetention;
        var expired = all.Where(p => p.Deleted && p.UpdatedAt < cutoff).ToList();
        if (expired.Count == 0)
        {
            return all;
        }

        await Task.WhenAll(expired.Select(async p =>
        {
            try
            {
                await playlistsContainer.DeleteItemAsync<Playlist>(
                    p.Id, new PartitionKey(userId), cancellationToken: cancellationToken);
            }
            catch (CosmosException ex) when (
                ex.StatusCode is HttpStatusCode.NotFound or HttpStatusCode.PreconditionFailed)
            {
                // Already gone or changed under us — nothing to GC.
            }
        }));

        var expiredIds = expired.Select(p => p.Id).ToHashSet();
        return all.Where(p => !expiredIds.Contains(p.Id)).ToList();
    }

    private async Task UpsertAsync(Playlist playlist, CancellationToken cancellationToken)
    {
        await playlistsContainer.UpsertItemAsync(
            playlist, new PartitionKey(playlist.UserId), cancellationToken: cancellationToken);
    }
}
