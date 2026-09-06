using System.Collections.Concurrent;
using System.Net;
using System.Threading;
using Microsoft.Azure.Cosmos;
using Microsoft.Extensions.DependencyInjection;
using Kuulla.Api.Models;

namespace Kuulla.Api.Services;

public class EpisodeService(
    [FromKeyedServices("episodes")] Container episodesContainer,
    // Read directly rather than through ISubscriptionService/IPlaylistService: both of those
    // services themselves depend on IEpisodeService, and taking the interface dependency here
    // would create a DI cycle.
    [FromKeyedServices("subscriptions")] Container subscriptionsContainer,
    [FromKeyedServices("playlists")] Container playlistsContainer,
    IShowService showService,
    IPodcastFeedClient feedClient,
    ISettingsService settingsService,
    IEpisodeStateService episodeStateService,
    IDeviceTokenService deviceTokenService,
    INotificationService notificationService,
    ILogger<EpisodeService> logger) : IEpisodeService
{
    // Excludes an episode from push notifications if its PublishedAt is older than this, even
    // though it's newly *inserted* into Cosmos — insertedEpisodes conflates "genuinely just
    // published" with "backfilled into the cache for the first time" (e.g. a user subscribing to
    // a show and viewing it for the first time caches its whole back catalog as "inserted"; the
    // very first poll of a show nobody's opened yet does the same). Gating on recency instead of
    // "was this the show's first-ever fetch" avoids notifying every subscriber about a show's
    // entire history the first time anyone looks at or polls it, without needing to track that
    // distinction separately. 48h comfortably covers the default 15-minute poll interval plus any
    // reasonable delay (a paused API instance, a slow feed) without being so wide it starts
    // catching genuine backfill.
    private static readonly TimeSpan RecentEpisodeWindow = TimeSpan.FromHours(48);

    public async Task<EpisodePage> GetEpisodesAsync(
        string showId,
        string? continuationToken,
        int pageSize,
        CancellationToken cancellationToken)
    {
        var page = await QueryEpisodesAsync(showId, continuationToken, pageSize, cancellationToken);

        // Nothing cached yet and this is the first page — populate from the show's feed
        // before returning, so a show's episodes show up the first time it's opened.
        if (page.Items.Count == 0 && continuationToken is null)
        {
            var show = await showService.GetByIdAsync(showId, cancellationToken);
            if (!string.IsNullOrEmpty(show?.FeedUrl))
            {
                var feed = await feedClient.FetchAsync(show.FeedUrl, cancellationToken);
                if (feed is { Episodes.Count: > 0 })
                {
                    await CacheEpisodesAsync(showId, feed.Episodes, cancellationToken);
                    page = await QueryEpisodesAsync(showId, continuationToken, pageSize, cancellationToken);
                }
            }
        }

        return page;
    }

    public async Task<Episode?> GetEpisodeAsync(string showId, string episodeId, CancellationToken cancellationToken)
    {
        var episode = await ReadEpisodeAsync(showId, episodeId, cancellationToken);
        if (episode is not null)
        {
            return episode;
        }

        // Not cached yet — mirror GetEpisodesAsync's first-load backfill so a direct or
        // shared link to a single episode works even if this show's episode list has
        // never been paged through in this app instance.
        var show = await showService.GetByIdAsync(showId, cancellationToken);
        if (string.IsNullOrEmpty(show?.FeedUrl))
        {
            return null;
        }

        var feed = await feedClient.FetchAsync(show.FeedUrl, cancellationToken);
        if (feed is not { Episodes.Count: > 0 })
        {
            return null;
        }

        await CacheEpisodesAsync(showId, feed.Episodes, cancellationToken);
        return await ReadEpisodeAsync(showId, episodeId, cancellationToken);
    }

    private async Task<Episode?> ReadEpisodeAsync(string showId, string episodeId, CancellationToken cancellationToken)
    {
        try
        {
            var response = await episodesContainer.ReadItemAsync<Episode>(
                episodeId, new PartitionKey(showId), cancellationToken: cancellationToken);
            return response.Resource;
        }
        catch (CosmosException ex) when (ex.StatusCode == HttpStatusCode.NotFound)
        {
            return null;
        }
    }

    // Cosmos's MaxItemCount is only a page-size *hint* — the (preview) emulator, and
    // potentially the live service, is free to return more per round trip. OFFSET/LIMIT
    // is an actual query bound, so it's used here instead to guarantee the page size.
    // Fetches one extra item beyond pageSize so we can tell whether a next page actually
    // exists, rather than guessing from whether this page happened to come back full.
    private async Task<EpisodePage> QueryEpisodesAsync(
        string showId,
        string? continuationToken,
        int pageSize,
        CancellationToken cancellationToken)
    {
        var offset = continuationToken is not null && int.TryParse(continuationToken, out var parsed) && parsed > 0
            ? parsed
            : 0;

        var queryDefinition = new QueryDefinition(
                "SELECT * FROM episodes e WHERE e.ShowId = @showId ORDER BY e.PublishedAt DESC OFFSET @offset LIMIT @fetchCount")
            .WithParameter("@showId", showId)
            .WithParameter("@offset", offset)
            .WithParameter("@fetchCount", pageSize + 1);

        var requestOptions = new QueryRequestOptions { PartitionKey = new PartitionKey(showId) };

        var items = new List<Episode>();
        using var iterator = episodesContainer.GetItemQueryIterator<Episode>(queryDefinition, requestOptions: requestOptions);
        while (iterator.HasMoreResults)
        {
            var response = await iterator.ReadNextAsync(cancellationToken);
            items.AddRange(response);
        }

        var hasMore = items.Count > pageSize;
        if (hasMore)
        {
            items.RemoveAt(items.Count - 1);
        }

        var nextToken = hasMore ? (offset + pageSize).ToString() : null;
        return new EpisodePage(items, nextToken);
    }

    // Create-only (never overwrites an existing cached episode) and capped at a modest
    // degree of parallelism — firing one Cosmos write per episode unbounded would throttle
    // on feeds with hundreds of episodes.
    public async Task CacheEpisodesAsync(string showId, IReadOnlyList<Episode> episodes, CancellationToken cancellationToken)
    {
        var insertedEpisodes = new ConcurrentBag<Episode>();
        await Parallel.ForEachAsync(
            episodes,
            new ParallelOptions { MaxDegreeOfParallelism = 20, CancellationToken = cancellationToken },
            async (episode, ct) =>
            {
                var stamped = episode with { ShowId = showId };
                try
                {
                    await episodesContainer.CreateItemAsync(stamped, new PartitionKey(showId), cancellationToken: ct);
                    insertedEpisodes.Add(stamped);
                }
                catch (CosmosException ex) when (ex.StatusCode == HttpStatusCode.Conflict)
                {
                }
            });

        // Nothing new actually landed (every item already existed) — skip the subscriber scan
        // entirely rather than re-running enforcement on every no-op refresh of an already-cached
        // show.
        if (insertedEpisodes.IsEmpty)
        {
            return;
        }

        // Single choke point where new episodes land in Cosmos — enforce every subscribed
        // user's unlistened-episode limit now rather than waiting for them to open the show.
        var subscriberIds = await GetSubscriberUserIdsAsync(showId, cancellationToken);
        await Parallel.ForEachAsync(
            subscriberIds,
            new ParallelOptions { MaxDegreeOfParallelism = 20, CancellationToken = cancellationToken },
            (userId, ct) => new ValueTask(EnforceUnlistenedLimitAsync(userId, showId, ct)));

        // New episodes may also need auto-inserting into any dynamic playlist that references this
        // show (#112) — separate from the per-subscriber loop above since a dynamic playlist isn't
        // scoped to this show's subscribers and can belong to any user.
        await InsertIntoDynamicPlaylistsAsync(showId, insertedEpisodes.ToList(), cancellationToken);

        // Keep each subscriber's Subscription.LatestEpisodePublishedAt fresh for the "Latest
        // episode" sort mode (#438), reusing the subscriberIds scan above. Only advances the
        // value, so a late-arriving old episode in this batch can't move a show backward.
        // Enumerable.Max on DateTimeOffset? skips nulls and returns null when every value is null.
        if (insertedEpisodes.Max(e => e.PublishedAt) is { } latestPublishedAt)
        {
            await UpdateSubscribersLatestEpisodeAsync(showId, subscriberIds, latestPublishedAt, cancellationToken);
        }

        // Push notifications (#216) — best-effort and gated to recently-published episodes only,
        // see RecentEpisodeWindow's doc comment above for why. Runs after (not folded into) the
        // subscriber-enforcement loop above so a notification failure can never affect the
        // unlistened-limit/playlist side effects those loops exist for.
        var now = DateTimeOffset.UtcNow;
        // publishedAt <= now guards against a future-dated PublishedAt (some feeds schedule
        // episodes ahead of release) — without it, `now - publishedAt` is negative and still
        // satisfies `<= RecentEpisodeWindow`, so a not-yet-released episode would count as
        // "recent" and trigger a notification for content that isn't actually out yet.
        var recentEpisodes = insertedEpisodes
            .Where(e => e.PublishedAt is { } publishedAt && publishedAt <= now && now - publishedAt <= RecentEpisodeWindow)
            .ToList();
        if (recentEpisodes.Count > 0 && subscriberIds.Count > 0)
        {
            await NotifySubscribersAsync(showId, subscriberIds, recentEpisodes, cancellationToken);

            // Auto-add to the "Up Next" queue for any subscriber whose effective
            // AutoAddNewEpisodesToUpNext is on (#440). Gated to recentEpisodes (not raw
            // insertedEpisodes) for the same reason NotifySubscribersAsync is — see
            // RecentEpisodeWindow's doc comment: a show's first-ever poll caches its whole back
            // catalogue as "inserted", and dumping all of that into every subscriber's queue is
            // never what "a newly polled episode appears in Up Next" means.
            await AutoAddToUpNextAsync(showId, subscriberIds, recentEpisodes, cancellationToken);
        }
    }

    private async Task NotifySubscribersAsync(
        string showId, IReadOnlyList<string> subscriberIds, IReadOnlyList<Episode> recentEpisodes, CancellationToken cancellationToken)
    {
        // Only fetched (an extra Cosmos read) once there's actually at least one subscriber to
        // notify — subscriberIds.Count > 0 is already checked by the caller above.
        var show = await showService.GetByIdAsync(showId, cancellationToken);
        if (show is null)
        {
            return;
        }

        await Parallel.ForEachAsync(
            subscriberIds,
            new ParallelOptions { MaxDegreeOfParallelism = 20, CancellationToken = cancellationToken },
            async (userId, ct) =>
            {
                try
                {
                    var notificationsEnabled = await settingsService.GetEffectiveNotificationsEnabledAsync(userId, showId, ct);
                    if (!notificationsEnabled)
                    {
                        return;
                    }

                    var tokens = await deviceTokenService.GetTokensForUserAsync(userId, ct);
                    if (tokens.Count == 0)
                    {
                        return;
                    }

                    await notificationService.NotifyNewEpisodesAsync(tokens, showId, show.Title, recentEpisodes, ct);
                }
                catch (Exception ex) when (ex is not OperationCanceledException)
                {
                    // A push-delivery failure for one subscriber is best-effort and must never
                    // fail episode caching itself (the reason CacheEpisodesAsync is called at
                    // all) — log and move on to the next subscriber.
                    logger.LogWarning(ex, "Failed to notify user {UserId} of new episodes for show {ShowId}", userId, showId);
                }
            });
    }

    // Appends (or prepends, per each user's UpNextInsertPosition) newly-cached episodes to a
    // subscriber's "Up Next" playlist when their effective AutoAddNewEpisodesToUpNext is on (#440),
    // creating that playlist on demand. Per-subscriber, best-effort with a per-user try/catch+log
    // — same shape and rationale as NotifySubscribersAsync above.
    private async Task AutoAddToUpNextAsync(
        string showId, IReadOnlyList<string> subscriberIds, IReadOnlyList<Episode> newEpisodes, CancellationToken cancellationToken)
    {
        if (subscriberIds.Count == 0 || newEpisodes.Count == 0)
        {
            return;
        }

        // Oldest first so a Top insert leaves the newest episode at the very top and a Bottom
        // insert appends in chronological order — same MinValue coalescing as
        // InsertIntoDynamicPlaylistsAsync for a feed that omits PublishedAt.
        var orderedNewEpisodes = newEpisodes.OrderBy(e => e.PublishedAt ?? DateTimeOffset.MinValue).ToList();

        await Parallel.ForEachAsync(
            subscriberIds,
            new ParallelOptions { MaxDegreeOfParallelism = 20, CancellationToken = cancellationToken },
            async (userId, ct) =>
            {
                try
                {
                    if (!await settingsService.GetEffectiveAutoAddNewEpisodesToUpNextAsync(userId, showId, ct))
                    {
                        return;
                    }

                    var settings = await settingsService.GetSettingsAsync(userId, ct);
                    await AddToUpNextWithRetryAsync(userId, orderedNewEpisodes, settings.UpNextInsertPosition, ct);
                }
                catch (Exception ex) when (ex is not OperationCanceledException)
                {
                    logger.LogWarning(
                        ex, "Failed to auto-add new episodes of show {ShowId} to Up Next for user {UserId}", showId, userId);
                }
            });
    }

    // Optimistic-concurrency retry around one user's Up Next playlist: re-reads (or creates) the
    // playlist before each attempt and upserts with IfMatchEtag, retrying on a lost race rather
    // than clobbering a concurrent edit — the same guarantee InsertIntoPlaylistWithRetryAsync
    // gives dynamic playlists. Skips episodes the user has already finished/archived and any
    // already in the queue.
    private async Task AddToUpNextWithRetryAsync(
        string userId, IReadOnlyList<Episode> newEpisodes, UpNextInsertPosition position, CancellationToken cancellationToken)
    {
        const int maxAttempts = 5;

        var states = await episodeStateService.GetStatesAsync(
            userId, newEpisodes.Select(e => e.Id).ToList(), cancellationToken);
        var candidates = newEpisodes
            .Where(e => !(states.TryGetValue(e.Id, out var state) && (state.Completed || state.Archived)))
            .ToList();
        if (candidates.Count == 0)
        {
            return;
        }

        for (var attempt = 0; attempt < maxAttempts; attempt++)
        {
            var (playlist, etag) = await ReadOrCreateUpNextPlaylistAsync(userId, cancellationToken);

            var existingEpisodeIds = playlist.Items.Select(item => item.EpisodeId).ToHashSet();
            var toAdd = candidates.Where(e => !existingEpisodeIds.Contains(e.Id)).ToList();
            if (toAdd.Count == 0)
            {
                return;
            }

            var items = playlist.Items.OrderBy(item => item.Order, StringComparer.Ordinal).ToList();
            var addedAt = DateTimeOffset.UtcNow;
            foreach (var episode in toAdd)
            {
                if (position == UpNextInsertPosition.Top)
                {
                    var after = items.Count > 0 ? items[0].Order : null;
                    items.Insert(0, new PlaylistItem(episode.Id, episode.ShowId, addedAt, PlaylistRankGenerator.Between(null, after)));
                }
                else
                {
                    var before = items.Count > 0 ? items[^1].Order : null;
                    items.Add(new PlaylistItem(episode.Id, episode.ShowId, addedAt, PlaylistRankGenerator.Between(before, null)));
                }
            }

            var updated = playlist with { Items = items, UpdatedAt = DateTimeOffset.UtcNow };
            try
            {
                await playlistsContainer.UpsertItemAsync(
                    updated, new PartitionKey(userId), new ItemRequestOptions { IfMatchEtag = etag }, cancellationToken);
                return;
            }
            catch (CosmosException ex) when (ex.StatusCode is HttpStatusCode.PreconditionFailed or HttpStatusCode.Conflict)
            {
                // Lost the race — PreconditionFailed: the playlist changed under us;
                // Conflict: a concurrent writer created "Up Next" first. Re-read and retry.
            }
        }

        throw new InvalidOperationException(
            $"Failed to auto-add episodes to the Up Next playlist for user '{userId}' after {maxAttempts} attempts.");
    }

    // Returns the user's oldest-by-CreatedAt "Up Next" playlist and its ETag (a point read after
    // the single-partition name query, since query results don't carry an ETag), creating an empty
    // manual playlist if the user has none. The oldest-wins tiebreak matches the client resolution
    // in UpNext.razor / UpNextView.swift for when a race left more than one.
    private async Task<(Playlist Playlist, string ETag)> ReadOrCreateUpNextPlaylistAsync(
        string userId, CancellationToken cancellationToken)
    {
        var query = new QueryDefinition("SELECT * FROM c WHERE c.UserId = @userId AND c.Name = @name")
            .WithParameter("@userId", userId)
            .WithParameter("@name", Playlist.UpNextName);

        Playlist? oldest = null;
        using var iterator = playlistsContainer.GetItemQueryIterator<Playlist>(
            query, requestOptions: new QueryRequestOptions { PartitionKey = new PartitionKey(userId) });
        while (iterator.HasMoreResults)
        {
            var page = await iterator.ReadNextAsync(cancellationToken);
            foreach (var playlist in page)
            {
                if (oldest is null || playlist.CreatedAt < oldest.CreatedAt)
                {
                    oldest = playlist;
                }
            }
        }

        if (oldest is not null)
        {
            var read = await playlistsContainer.ReadItemAsync<Playlist>(
                oldest.Id, new PartitionKey(userId), cancellationToken: cancellationToken);
            return (read.Resource, read.ETag);
        }

        var now = DateTimeOffset.UtcNow;
        var created = new Playlist(
            Guid.NewGuid().ToString(), userId, Playlist.UpNextName, PlaylistType.Manual, [], now, now);
        var response = await playlistsContainer.CreateItemAsync(
            created, new PartitionKey(userId), cancellationToken: cancellationToken);
        return (response.Resource, response.ETag);
    }

    // Finds every dynamic playlist referencing showId and inserts each newly-cached episode into
    // it at the position its PriorityList/PublishedAt ordering dictates, then enforces MaxEpisodes
    // by evicting from the tail. Mirrors PlaylistService.ComputeDynamicItemsAsync's ordering rules
    // but applies them incrementally (one item at a time, touching only that item's Order) rather
    // than rebuilding the whole Items array — see #112.
    private async Task InsertIntoDynamicPlaylistsAsync(
        string showId, IReadOnlyList<Episode> newEpisodes, CancellationToken cancellationToken)
    {
        if (newEpisodes.Count == 0)
        {
            return;
        }

        var playlists = await QueryDynamicPlaylistsForShowAsync(showId, cancellationToken);
        if (playlists.Count == 0)
        {
            return;
        }

        // Oldest first so each insertion's midpoint rank calc only ever has to reason about items
        // already placed, not ones still to come. PublishedAt is nullable (RSS feeds don't always
        // supply it) — coalesce to MinValue so a missing PublishedAt sorts as "oldest" consistently
        // rather than floating wherever OrderBy happens to place a null.
        var orderedNewEpisodes = newEpisodes.OrderBy(e => e.PublishedAt ?? DateTimeOffset.MinValue).ToList();

        // Each playlist's read-modify-write is independent (different UserId partition, no shared
        // state) — same "many independent per-entity Cosmos operations" shape as the episode-create
        // and subscriber-enforcement fan-out above.
        await Parallel.ForEachAsync(
            playlists,
            new ParallelOptions { MaxDegreeOfParallelism = 20, CancellationToken = cancellationToken },
            (playlist, ct) => new ValueTask(
                InsertIntoPlaylistWithRetryAsync(playlist.Id, playlist.UserId, orderedNewEpisodes, ct)));
    }

    // Optimistic-concurrency retry around a single playlist's insert: re-reads the playlist (and
    // its ETag) before every attempt and upserts with IfMatchEtag, retrying on a lost race instead
    // of blindly overwriting. Without this, two shows referenced by the same multi-show dynamic
    // playlist landing new episodes concurrently could each read the same version, compute
    // independent updates, and have the second UpsertItemAsync silently discard the first's insert
    // — the kind of whole-document last-write-wins CLAUDE.md's "CRDTs if needed for queue ordering"
    // note calls out as unacceptable for playlist contents (unlike playback position, where
    // last-write-wins is fine).
    private async Task InsertIntoPlaylistWithRetryAsync(
        string playlistId, string userId, IReadOnlyList<Episode> newEpisodes, CancellationToken cancellationToken)
    {
        const int maxAttempts = 5;

        // Keyed by EpisodeId, shared across every new episode and every retry attempt for this
        // playlist — an existing item's PublishedAt never changes, so it only needs reading once
        // regardless of how many new episodes are being placed or how many times the optimistic
        // write is retried.
        var episodeCache = new Dictionary<string, Episode?>();

        for (var attempt = 0; attempt < maxAttempts; attempt++)
        {
            ItemResponse<Playlist> response;
            try
            {
                response = await playlistsContainer.ReadItemAsync<Playlist>(
                    playlistId, new PartitionKey(userId), cancellationToken: cancellationToken);
            }
            catch (CosmosException ex) when (ex.StatusCode == HttpStatusCode.NotFound)
            {
                return; // Deleted concurrently — nothing left to insert into.
            }

            var current = response.Resource;
            var changed = false;
            foreach (var episode in newEpisodes)
            {
                var next = await TryInsertEpisodeAsync(current, episode, episodeCache, cancellationToken);
                if (next is null)
                {
                    continue;
                }

                current = next;
                changed = true;
            }

            if (!changed)
            {
                return;
            }

            try
            {
                await playlistsContainer.UpsertItemAsync(
                    current,
                    new PartitionKey(userId),
                    new ItemRequestOptions { IfMatchEtag = response.ETag },
                    cancellationToken);
                return;
            }
            catch (CosmosException ex) when (ex.StatusCode == HttpStatusCode.PreconditionFailed)
            {
                // Lost the race to a concurrent writer — loop around and retry against whatever
                // it just wrote.
            }
        }

        // Exhausted every attempt still losing the optimistic-concurrency race — surface this
        // rather than silently dropping the insert, which would undermine the whole point of the
        // ETag/retry loop above.
        throw new InvalidOperationException(
            $"Failed to insert into playlist '{playlistId}' after {maxAttempts} attempts due to concurrent writes.");
    }

    // Returns null (no-op) if the episode is already present — per-user fan-out for a new episode
    // across many dynamic playlists must be safe to re-run, mirroring #98's idempotent-by-
    // construction design.
    private async Task<Playlist?> TryInsertEpisodeAsync(
        Playlist playlist, Episode episode, Dictionary<string, Episode?> episodeCache, CancellationToken cancellationToken)
    {
        var config = playlist.DynamicConfig;
        if (config is null || playlist.Items.Any(item => item.EpisodeId == episode.Id))
        {
            return null;
        }

        var priorityRank = config.PriorityList
            .Select((id, index) => (id, index))
            .ToDictionary(x => x.id, x => x.index);
        var newRank = priorityRank.GetValueOrDefault(episode.ShowId, int.MaxValue);

        // playlist.Items is already sorted by Order, which was itself built respecting
        // priority-then-recency — walk it once to find the index the new item belongs at.
        // Higher-priority shows (or, within the same show, newer episodes) stay before;
        // everything else falls after. beforeOrder/afterOrder are the resulting neighbors'
        // Order strings; insertIndex defaults to appending at the end if the loop never breaks.
        string? beforeOrder = null;
        string? afterOrder = null;
        var insertIndex = playlist.Items.Count;
        for (var i = 0; i < playlist.Items.Count; i++)
        {
            var item = playlist.Items[i];
            var itemRank = priorityRank.GetValueOrDefault(item.ShowId, int.MaxValue);
            if (itemRank < newRank)
            {
                beforeOrder = item.Order;
                continue;
            }

            if (itemRank > newRank)
            {
                afterOrder = item.Order;
                insertIndex = i;
                break;
            }

            if (!episodeCache.TryGetValue(item.EpisodeId, out var itemEpisode))
            {
                itemEpisode = await ReadEpisodeAsync(item.ShowId, item.EpisodeId, cancellationToken);
                episodeCache[item.EpisodeId] = itemEpisode;
            }

            // Same MinValue sentinel as above — a missing PublishedAt on either side must still
            // compare deterministically instead of the null-propagating `?.` making `>` false (and
            // so treating the item as "not newer") for both a genuinely older episode and a
            // genuinely missing PublishedAt.
            var itemPublishedAt = itemEpisode?.PublishedAt ?? DateTimeOffset.MinValue;
            if (itemPublishedAt > (episode.PublishedAt ?? DateTimeOffset.MinValue))
            {
                beforeOrder = item.Order;
                continue;
            }

            afterOrder = item.Order;
            insertIndex = i;
            break;
        }

        // The scan above already found the exact insertion point, and PlaylistRankGenerator.
        // Between guarantees the new Order sorts strictly between beforeOrder/afterOrder — an
        // indexed insert keeps the list sorted without re-sorting every other (already-sorted)
        // item.
        var order = PlaylistRankGenerator.Between(beforeOrder, afterOrder);
        var items = new List<PlaylistItem>(playlist.Items);
        items.Insert(insertIndex, new PlaylistItem(episode.Id, episode.ShowId, DateTimeOffset.UtcNow, order));

        items = await EvictOverflowAsync(playlist.UserId, items, config.MaxEpisodes, cancellationToken);

        return playlist with { Items = items, UpdatedAt = DateTimeOffset.UtcNow };
    }

    // Evicts from the tail (lowest priority / oldest, since items is Order-sorted) down to
    // MaxEpisodes — or PlaylistRankGenerator.UnboundedSafetyCap when the playlist has no explicit
    // MaxEpisodes, the same fallback PlaylistService.ComputeDynamicItemsAsync applies for a
    // full rebuild, so an unbounded dynamic playlist can't grow past Cosmos's document size limit
    // via incremental inserts either. Skips — never evicts — an episode with in-progress playback
    // state, matching the "never overwrite a manual play" caution #98 established for episode
    // state. If every tail item beyond the cap turns out to be protected, the playlist is left
    // over the cap rather than discarding progress; that's the "if avoidable" the issue calls for,
    // not a bug.
    private async Task<List<PlaylistItem>> EvictOverflowAsync(
        string userId, List<PlaylistItem> items, int? maxEpisodes, CancellationToken cancellationToken)
    {
        var effectiveCap = maxEpisodes ?? PlaylistRankGenerator.UnboundedSafetyCap;
        if (items.Count <= effectiveCap)
        {
            return items;
        }

        var overflow = items.Count - effectiveCap;
        for (var i = items.Count - 1; i >= 0 && overflow > 0; i--)
        {
            var state = await episodeStateService.GetStateAsync(userId, items[i].EpisodeId, cancellationToken);
            if (state is { PositionSeconds: > 0 })
            {
                continue;
            }

            items.RemoveAt(i);
            overflow--;
        }

        return items;
    }

    private async Task<IReadOnlyList<Playlist>> QueryDynamicPlaylistsForShowAsync(string showId, CancellationToken cancellationToken)
    {
        // IS_DEFINED(DynamicConfig) rather than filtering on the Type enum — avoids relying on how
        // PlaylistType happens to be serialized (int vs. string) and only Dynamic playlists ever
        // have DynamicConfig set. Cross-partition (playlists are partitioned by UserId, and a
        // dynamic playlist referencing this show could belong to any user) but off the hot path,
        // same tradeoff GetSubscriberUserIdsAsync below makes.
        var queryDefinition = new QueryDefinition(
                "SELECT * FROM c WHERE IS_DEFINED(c.DynamicConfig) AND ARRAY_CONTAINS(c.DynamicConfig.ShowIds, @showId)")
            .WithParameter("@showId", showId);

        var results = new List<Playlist>();
        using var iterator = playlistsContainer.GetItemQueryIterator<Playlist>(queryDefinition);
        while (iterator.HasMoreResults)
        {
            var page = await iterator.ReadNextAsync(cancellationToken);
            results.AddRange(page);
        }

        return results;
    }

    // Advances Subscription.LatestEpisodePublishedAt for every subscriber of this show (#438).
    // Point read + conditional upsert per row (subscriptions are partitioned by UserId, id ==
    // ShowId) rather than a cross-partition patch, matching how the rest of this service touches
    // the subscriptions container. Best-effort: a per-row failure is logged and skipped so it
    // can't fail episode caching itself — the value self-heals on the next feed poll.
    private async Task UpdateSubscribersLatestEpisodeAsync(
        string showId, IReadOnlyList<string> subscriberIds, DateTimeOffset latestEpisodePublishedAt, CancellationToken cancellationToken)
    {
        await Parallel.ForEachAsync(
            subscriberIds,
            new ParallelOptions { MaxDegreeOfParallelism = 20, CancellationToken = cancellationToken },
            async (userId, ct) =>
            {
                try
                {
                    var existing = await subscriptionsContainer.ReadItemAsync<Subscription>(
                        showId, new PartitionKey(userId), cancellationToken: ct);

                    if (existing.Resource.LatestEpisodePublishedAt is { } current && current >= latestEpisodePublishedAt)
                    {
                        return;
                    }

                    var updated = existing.Resource with { LatestEpisodePublishedAt = latestEpisodePublishedAt };
                    await subscriptionsContainer.UpsertItemAsync(
                        updated, new PartitionKey(userId), new ItemRequestOptions { IfMatchEtag = existing.ETag }, ct);
                }
                catch (CosmosException ex) when (ex.StatusCode is HttpStatusCode.NotFound or HttpStatusCode.PreconditionFailed)
                {
                    // NotFound: the subscription was removed between the scan and this write.
                    // PreconditionFailed: a concurrent write beat us — the next poll retries.
                }
                catch (Exception ex)
                {
                    logger.LogWarning(
                        ex, "Failed to update LatestEpisodePublishedAt for user {UserId} on show {ShowId}", userId, showId);
                }
            });
    }

    private async Task<IReadOnlyList<string>> GetSubscriberUserIdsAsync(string showId, CancellationToken cancellationToken)
    {
        var results = new List<string>();
        var queryDefinition = new QueryDefinition("SELECT VALUE c.UserId FROM c WHERE c.ShowId = @showId")
            .WithParameter("@showId", showId);

        using var iterator = subscriptionsContainer.GetItemQueryIterator<string>(queryDefinition);
        while (iterator.HasMoreResults)
        {
            var page = await iterator.ReadNextAsync(cancellationToken);
            results.AddRange(page);
        }

        return results;
    }

    public async Task EnforceUnlistenedLimitAsync(string userId, string showId, CancellationToken cancellationToken)
    {
        var effectiveLimit = await settingsService.GetEffectiveUnlistenedEpisodeCountAsync(userId, showId, cancellationToken);
        if (effectiveLimit == UnlistenedEpisodeCount.Unlimited)
        {
            return;
        }

        var episodes = await GetAllEpisodesOrderedAsync(showId, cancellationToken);
        var beyondLimit = episodes.Skip((int)effectiveLimit);

        var toMark = new List<(string EpisodeId, string ShowId)>();
        foreach (var episode in beyondLimit)
        {
            // Never overwrite a manual play, an in-progress position, or a previous manual
            // "mark unplayed" — only touch episodes with no existing state at all.
            var existingState = await episodeStateService.GetStateAsync(userId, episode.Id, cancellationToken);
            if (existingState is null)
            {
                toMark.Add((episode.Id, showId));
            }
        }

        // Batched so the sync summary is recomputed once per enforcement run rather than once per
        // marked episode — a back catalog with hundreds of episodes beyond the limit would
        // otherwise trigger hundreds of redundant QueryAllStatesAsync + cache-set round trips.
        await episodeStateService.MarkAutoPlayedAsync(userId, toMark, cancellationToken);
    }

    // Archiving is purely a visibility flag on EpisodeState (#187) — it hides played episodes
    // from active lists once the effective rule's delay has elapsed since they were played, and
    // never un-archives (a later rule change to Never just stops archiving anything new; it
    // doesn't retroactively unhide episodes already archived under a stricter rule).
    public async Task EnforceAutoArchiveRuleAsync(string userId, string showId, CancellationToken cancellationToken)
    {
        var rule = await settingsService.GetEffectiveAutoArchiveRuleAsync(userId, showId, cancellationToken);
        if (rule == AutoArchiveRule.Never)
        {
            return;
        }

        var delay = rule.ArchiveDelay();
        var now = DateTimeOffset.UtcNow;
        var states = await episodeStateService.GetShowStatesAsync(userId, showId, cancellationToken);

        var toArchive = states
            .Where(state => state.Completed && !state.Archived && state.PlayedAt is not null)
            .Where(state => now - state.PlayedAt!.Value >= delay)
            .ToList();

        await episodeStateService.SetArchivedAsync(userId, toArchive, archived: true, cancellationToken);
    }

    public async Task<IReadOnlyList<Episode>> GetAllEpisodesOrderedAsync(string showId, CancellationToken cancellationToken)
    {
        var queryDefinition = new QueryDefinition(
                "SELECT * FROM c WHERE c.ShowId = @showId ORDER BY c.PublishedAt DESC")
            .WithParameter("@showId", showId);
        var requestOptions = new QueryRequestOptions { PartitionKey = new PartitionKey(showId) };

        var items = new List<Episode>();
        using var iterator = episodesContainer.GetItemQueryIterator<Episode>(queryDefinition, requestOptions: requestOptions);
        while (iterator.HasMoreResults)
        {
            var response = await iterator.ReadNextAsync(cancellationToken);
            items.AddRange(response);
        }

        return items;
    }

    public async Task<DateTimeOffset?> GetNewestCachedEpisodePublishedAtAsync(string showId, CancellationToken cancellationToken)
    {
        // Single-partition, single-item read — no feed fallback (that's GetEpisodesAsync's job).
        // Cosmos orders nulls first under DESC, so the WHERE guard keeps LIMIT 1 landing on the
        // newest episode that actually has a publish date.
        var queryDefinition = new QueryDefinition(
                "SELECT VALUE c.PublishedAt FROM c WHERE c.ShowId = @showId AND IS_DEFINED(c.PublishedAt) AND c.PublishedAt != null " +
                "ORDER BY c.PublishedAt DESC OFFSET 0 LIMIT 1")
            .WithParameter("@showId", showId);
        var requestOptions = new QueryRequestOptions { PartitionKey = new PartitionKey(showId) };

        using var iterator = episodesContainer.GetItemQueryIterator<DateTimeOffset?>(queryDefinition, requestOptions: requestOptions);
        while (iterator.HasMoreResults)
        {
            var response = await iterator.ReadNextAsync(cancellationToken);
            foreach (var publishedAt in response)
            {
                return publishedAt;
            }
        }

        return null;
    }
}
