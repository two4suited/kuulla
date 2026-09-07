using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Xml;
using Microsoft.Azure.Cosmos;
using Microsoft.Extensions.DependencyInjection;
using Kuulla.Core.Models;

namespace Kuulla.Core.Services;

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

    public async Task<Show?> GetOrCreateByFeedUrlAsync(string feedUrl, CancellationToken cancellationToken)
    {
        var normalized = FeedUrl.Normalize(feedUrl);

        // FeedUrl.Normalize hands back anything it can't canonicalise unchanged (a non-absolute
        // or non-http string). There's nothing to fetch from that, and passing it to HttpClient
        // would throw an uncaught InvalidOperationException that fails the whole import — treat
        // it as a per-entry failure instead.
        if (!Uri.TryCreate(normalized, UriKind.Absolute, out var feedUri)
            || (feedUri.Scheme != Uri.UriSchemeHttp && feedUri.Scheme != Uri.UriSchemeHttps))
        {
            return null;
        }

        var id = FeedShowId(normalized);

        try
        {
            var existing = await showsContainer.ReadItemAsync<Show>(
                id, new PartitionKey(id), cancellationToken: cancellationToken);
            return existing.Resource;
        }
        catch (CosmosException ex) when (ex.StatusCode == HttpStatusCode.NotFound)
        {
            // First time this feed has been seen — fall through and create it from the feed.
        }

        PodcastFeedContent? feed;
        try
        {
            feed = await feedClient.FetchAsync(normalized, cancellationToken);
        }
        catch (Exception ex) when (ex is HttpRequestException or XmlException or TaskCanceledException)
        {
            // Unreachable, timed out, or not valid XML — the caller records a per-entry failure.
            return null;
        }

        if (feed is null)
        {
            return null;
        }

        var show = new Show(
            id,
            feed.Title ?? normalized,
            feed.Author ?? string.Empty,
            normalized,
            feed.ArtworkUrl,
            feed.Description,
            Categories: []);

        try
        {
            var response = await showsContainer.CreateItemAsync(
                show, new PartitionKey(id), cancellationToken: cancellationToken);
            return response.Resource;
        }
        catch (CosmosException ex) when (ex.StatusCode == HttpStatusCode.Conflict)
        {
            // A concurrent import of the same feed won the race — read back its record rather
            // than clobbering it, mirroring CacheAsync's create-only discipline.
            var existing = await showsContainer.ReadItemAsync<Show>(
                id, new PartitionKey(id), cancellationToken: cancellationToken);
            return existing.Resource;
        }
    }

    // Deterministic Show.Id for a feed-URL-sourced show: a stable hash of the normalized URL so
    // every import of the same feed maps to one showsContainer item. Prefixed to keep it visibly
    // distinct from the numeric iTunes collectionId used for directory-sourced shows.
    private static string FeedShowId(string normalizedFeedUrl)
    {
        var bytes = SHA256.HashData(Encoding.UTF8.GetBytes(normalizedFeedUrl));
        return "feed-" + Convert.ToHexString(bytes)[..32].ToLowerInvariant();
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
