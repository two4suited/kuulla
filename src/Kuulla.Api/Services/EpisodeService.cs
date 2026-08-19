using System.Net;
using Microsoft.Azure.Cosmos;
using Microsoft.Extensions.DependencyInjection;
using Kuulla.Api.Models;

namespace Kuulla.Api.Services;

public class EpisodeService(
    [FromKeyedServices("episodes")] Container episodesContainer,
    // Read directly rather than through ISubscriptionService: SubscriptionService itself depends
    // on IEpisodeService, and taking the interface dependency here would create a DI cycle.
    [FromKeyedServices("subscriptions")] Container subscriptionsContainer,
    IShowService showService,
    IPodcastFeedClient feedClient,
    ISettingsService settingsService,
    IEpisodeStateService episodeStateService) : IEpisodeService
{
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
    private async Task CacheEpisodesAsync(string showId, IReadOnlyList<Episode> episodes, CancellationToken cancellationToken)
    {
        await Parallel.ForEachAsync(
            episodes,
            new ParallelOptions { MaxDegreeOfParallelism = 20, CancellationToken = cancellationToken },
            async (episode, ct) =>
            {
                var stamped = episode with { ShowId = showId };
                try
                {
                    await episodesContainer.CreateItemAsync(stamped, new PartitionKey(showId), cancellationToken: ct);
                }
                catch (CosmosException ex) when (ex.StatusCode == HttpStatusCode.Conflict)
                {
                }
            });

        // Single choke point where new episodes land in Cosmos — enforce every subscribed
        // user's unlistened-episode limit now rather than waiting for them to open the show.
        var subscriberIds = await GetSubscriberUserIdsAsync(showId, cancellationToken);
        await Parallel.ForEachAsync(
            subscriberIds,
            new ParallelOptions { MaxDegreeOfParallelism = 20, CancellationToken = cancellationToken },
            (userId, ct) => new ValueTask(EnforceUnlistenedLimitAsync(userId, showId, ct)));
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

        foreach (var episode in beyondLimit)
        {
            // Never overwrite a manual play, an in-progress position, or a previous manual
            // "mark unplayed" — only touch episodes with no existing state at all.
            var existingState = await episodeStateService.GetStateAsync(userId, episode.Id, cancellationToken);
            if (existingState is not null)
            {
                continue;
            }

            await episodeStateService.MarkAutoPlayedAsync(userId, episode.Id, showId, cancellationToken);
        }
    }

    private async Task<IReadOnlyList<Episode>> GetAllEpisodesOrderedAsync(string showId, CancellationToken cancellationToken)
    {
        var queryDefinition = new QueryDefinition(
                "SELECT * FROM episodes e WHERE e.ShowId = @showId ORDER BY e.PublishedAt DESC")
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
}
