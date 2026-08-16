using System.Net;
using Microsoft.Azure.Cosmos;
using Microsoft.Extensions.DependencyInjection;
using Kuulla.Api.Models;

namespace Kuulla.Api.Services;

public class EpisodeService(
    [FromKeyedServices("episodes")] Container episodesContainer,
    IShowService showService,
    IPodcastFeedClient feedClient) : IEpisodeService
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
    }
}
