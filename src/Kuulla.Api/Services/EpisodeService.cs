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
                    await UpsertEpisodesAsync(showId, feed.Episodes, cancellationToken);
                    page = await QueryEpisodesAsync(showId, continuationToken, pageSize, cancellationToken);
                }
            }
        }

        return page;
    }

    // Cosmos's MaxItemCount is only a page-size *hint* — the (preview) emulator, and
    // potentially the live service, is free to return more per round trip. OFFSET/LIMIT
    // is an actual query bound, so it's used here instead to guarantee the page size.
    private async Task<EpisodePage> QueryEpisodesAsync(
        string showId,
        string? continuationToken,
        int pageSize,
        CancellationToken cancellationToken)
    {
        var offset = continuationToken is not null && int.TryParse(continuationToken, out var parsed) ? parsed : 0;

        var queryDefinition = new QueryDefinition(
                "SELECT * FROM episodes e WHERE e.ShowId = @showId ORDER BY e.PublishedAt DESC OFFSET @offset LIMIT @pageSize")
            .WithParameter("@showId", showId)
            .WithParameter("@offset", offset)
            .WithParameter("@pageSize", pageSize);

        var requestOptions = new QueryRequestOptions { PartitionKey = new PartitionKey(showId) };

        var items = new List<Episode>();
        using var iterator = episodesContainer.GetItemQueryIterator<Episode>(queryDefinition, requestOptions: requestOptions);
        while (iterator.HasMoreResults)
        {
            var response = await iterator.ReadNextAsync(cancellationToken);
            items.AddRange(response);
        }

        var nextToken = items.Count == pageSize ? (offset + pageSize).ToString() : null;
        return new EpisodePage(items, nextToken);
    }

    private async Task UpsertEpisodesAsync(string showId, IReadOnlyList<Episode> episodes, CancellationToken cancellationToken)
    {
        await Task.WhenAll(episodes.Select(async episode =>
        {
            var stamped = episode with { ShowId = showId };
            try
            {
                await episodesContainer.CreateItemAsync(stamped, new PartitionKey(showId), cancellationToken: cancellationToken);
            }
            catch (CosmosException ex) when (ex.StatusCode == HttpStatusCode.Conflict)
            {
            }
        }));
    }
}
