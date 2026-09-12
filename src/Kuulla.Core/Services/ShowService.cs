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

    public async Task<FeedShow?> GetOrCreateByFeedUrlAsync(string feedUrl, CancellationToken cancellationToken)
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

        Show? existingShow = null;
        try
        {
            var existing = await showsContainer.ReadItemAsync<Show>(
                id, new PartitionKey(id), cancellationToken: cancellationToken);
            existingShow = existing.Resource;
        }
        catch (CosmosException ex) when (ex.StatusCode == HttpStatusCode.NotFound)
        {
            // First time this feed has been seen — fall through and create it from the feed.
        }

        // Fetch the feed for the newest-episode date that seeds the "Latest episode" sort key
        // (#501, #516). This runs even when the show already exists globally: OPML import caches
        // no episodes, so a known show with an empty episode cache would otherwise subscribe with
        // a null sort key and clump at the bottom of "Latest episode". The only caller filters
        // out feeds the user is already subscribed to, so this fetch is one-per-newly-added show
        // and gated by the import's own concurrency limit.
        PodcastFeedContent? feed;
        try
        {
            feed = await feedClient.FetchAsync(normalized, cancellationToken);
        }
        catch (Exception ex) when (ex is HttpRequestException or XmlException or TaskCanceledException)
        {
            // Unreachable, timed out, or not valid XML. For a brand-new feed the caller records a
            // per-entry failure (null below); for a show we already have, the subscribe still
            // succeeds — just without a fresh sort key.
            feed = null;
        }

        // Max over DateTimeOffset? skips nulls and is null when the feed has no dated episodes
        // (or couldn't be fetched).
        var latestEpisodePublishedAt = feed?.Episodes.Max(e => e.PublishedAt);

        if (existingShow is not null)
        {
            return new FeedShow(existingShow, latestEpisodePublishedAt);
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
            return new FeedShow(response.Resource, latestEpisodePublishedAt);
        }
        catch (CosmosException ex) when (ex.StatusCode == HttpStatusCode.Conflict)
        {
            // A concurrent import of the same feed won the race — read back its record rather
            // than clobbering it, mirroring CacheAsync's create-only discipline. We still fetched
            // the feed, so the newest-episode date we computed is good to hand back.
            var existing = await showsContainer.ReadItemAsync<Show>(
                id, new PartitionKey(id), cancellationToken: cancellationToken);
            return new FeedShow(existing.Resource, latestEpisodePublishedAt);
        }
    }

    public async Task<string?> TryGetFeedUrlAsync(string showId, CancellationToken cancellationToken)
    {
        try
        {
            var response = await showsContainer.ReadItemAsync<Show>(
                showId, new PartitionKey(showId), cancellationToken: cancellationToken);
            return string.IsNullOrEmpty(response.Resource.FeedUrl) ? null : response.Resource.FeedUrl;
        }
        catch (CosmosException ex) when (ex.StatusCode == HttpStatusCode.NotFound)
        {
            return null;
        }
    }

    // Deterministic Show.Id for a feed-URL-sourced show: a stable hash of the normalized URL
    // (FeedUrl.Normalize) so every import of the same feed maps to one showsContainer item.
    // Prefixed to keep it visibly distinct from the numeric iTunes collectionId used for
    // directory-sourced shows. Public so callers that need to address a would-be feed show by id
    // (e.g. seeding it in tests) don't have to re-derive the scheme.
    public static string FeedShowId(string normalizedFeedUrl)
    {
        var bytes = SHA256.HashData(Encoding.UTF8.GetBytes(normalizedFeedUrl));
        return "feed-" + Convert.ToHexString(bytes)[..32].ToLowerInvariant();
    }

    public async Task UpdateFeedPollCursorAsync(
        string showId, string? feedEtag, string? feedLastModified, CancellationToken cancellationToken)
    {
        try
        {
            // Patch rather than read-modify-write upsert — this runs once per polled show every
            // sweep and only ever touches these two fields, so a single PATCH request (no read,
            // no ETag/concurrency dance) is both cheaper and can't race a concurrent enrichment
            // write to Description elsewhere in this class.
            var patchOperations = new List<PatchOperation>
            {
                PatchOperation.Set("/FeedEtag", feedEtag),
                PatchOperation.Set("/FeedLastModified", feedLastModified),
            };
            await showsContainer.PatchItemAsync<Show>(
                showId, new PartitionKey(showId), patchOperations, cancellationToken: cancellationToken);
        }
        catch (CosmosException ex) when (ex.StatusCode == HttpStatusCode.NotFound)
        {
            // Show was deleted between the poll and this write — nothing left to update.
        }
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
