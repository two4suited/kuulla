using System.Net;
using Microsoft.Azure.Cosmos;
using Microsoft.Extensions.DependencyInjection;
using Kuulla.Api.Models;

namespace Kuulla.Api.Services;

public class ShowService(
    [FromKeyedServices("shows")] Container showsContainer,
    IPodcastDirectoryClient directoryClient,
    IPodcastFeedClient feedClient) : IShowService
{
    public async Task<IReadOnlyList<Show>> SearchAsync(string query, CancellationToken cancellationToken)
    {
        var results = await directoryClient.SearchAsync(query, cancellationToken);
        await CacheAsync(results, cancellationToken);
        return results;
    }

    public async Task<IReadOnlyList<Show>> GetTrendingAsync(string? category, CancellationToken cancellationToken)
    {
        var results = await directoryClient.GetTrendingAsync(category, cancellationToken);
        await CacheAsync(results, cancellationToken);
        return results;
    }

    // Cache discovered shows so GetByIdAsync/episode lookups have something to work from.
    // Create-only: never clobber a record we've already enriched with a feed-derived description.
    private async Task CacheAsync(IReadOnlyList<Show> shows, CancellationToken cancellationToken)
    {
        await Task.WhenAll(shows.Select(async show =>
        {
            try
            {
                await showsContainer.CreateItemAsync(show, new PartitionKey(show.Id), cancellationToken: cancellationToken);
            }
            catch (CosmosException ex) when (ex.StatusCode == HttpStatusCode.Conflict)
            {
            }
        }));
    }

    public async Task<Show?> GetByIdAsync(string id, CancellationToken cancellationToken)
    {
        Show show;
        try
        {
            var response = await showsContainer.ReadItemAsync<Show>(id, new PartitionKey(id), cancellationToken: cancellationToken);
            show = response.Resource;
        }
        catch (CosmosException ex) when (ex.StatusCode == HttpStatusCode.NotFound)
        {
            return null;
        }

        if (!string.IsNullOrEmpty(show.Description) || string.IsNullOrEmpty(show.FeedUrl))
        {
            return show;
        }

        var feed = await feedClient.FetchAsync(show.FeedUrl, cancellationToken);
        if (string.IsNullOrEmpty(feed?.Description))
        {
            return show;
        }

        show = show with { Description = feed.Description };
        await showsContainer.UpsertItemAsync(show, new PartitionKey(show.Id), cancellationToken: cancellationToken);
        return show;
    }
}
