using System.Net;
using System.Xml;
using Microsoft.Azure.Cosmos;
using Microsoft.Extensions.DependencyInjection;
using Kuulla.Api.Models;

namespace Kuulla.Api.Services;

public class SubscriptionService(
    [FromKeyedServices("subscriptions")] Container subscriptionsContainer,
    IShowService showService,
    IEpisodeService episodeService,
    IEpisodeStateService episodeStateService) : ISubscriptionService
{
    // "New" per show: the most recently published episodes the user has never touched (no
    // EpisodeState record at all). No existing convention to reuse here — a "last seen" marker
    // per subscription doesn't exist yet, so this is the simplest read of the issue's "new
    // episodes across all subscriptions" that doesn't require adding new per-subscription state.
    private const int NewEpisodesPerShow = 10;
    public async Task<IReadOnlyList<Subscription>> GetSubscriptionsAsync(string userId, CancellationToken cancellationToken)
    {
        var results = new List<Subscription>();
        using var iterator = subscriptionsContainer.GetItemQueryIterator<Subscription>(
            new QueryDefinition("SELECT * FROM c"),
            requestOptions: new QueryRequestOptions { PartitionKey = new PartitionKey(userId) });

        while (iterator.HasMoreResults)
        {
            var page = await iterator.ReadNextAsync(cancellationToken);
            results.AddRange(page);
        }

        return results;
    }

    public async Task<Subscription?> SubscribeAsync(string userId, string showId, CancellationToken cancellationToken)
    {
        var show = await showService.GetByIdAsync(showId, cancellationToken);
        if (show is null)
        {
            return null;
        }

        // Seed the newest-episode date for the "Latest episode" sort mode (#438) from what's
        // already cached — no live feed fetch, so subscribe stays a fast point operation. If
        // nothing is cached yet the value stays null; the first show-open and every feed poll
        // run CacheEpisodesAsync, which backfills it for all subscribers.
        var latestEpisodePublishedAt = await episodeService.GetNewestCachedEpisodePublishedAtAsync(showId, cancellationToken);

        var subscription = new Subscription(
            showId,
            userId,
            showId,
            show.Title,
            show.Author,
            show.ArtworkUrl,
            DateTimeOffset.UtcNow,
            latestEpisodePublishedAt);

        try
        {
            var response = await subscriptionsContainer.CreateItemAsync(
                subscription, new PartitionKey(userId), cancellationToken: cancellationToken);
            return response.Resource;
        }
        catch (CosmosException ex) when (ex.StatusCode == HttpStatusCode.Conflict)
        {
            // Already subscribed — idempotent, return the existing subscription rather than
            // clobbering its original SubscribedAt.
            var existing = await subscriptionsContainer.ReadItemAsync<Subscription>(
                showId, new PartitionKey(userId), cancellationToken: cancellationToken);
            return existing.Resource;
        }
    }

    public async Task UnsubscribeAsync(string userId, string showId, CancellationToken cancellationToken)
    {
        try
        {
            await subscriptionsContainer.DeleteItemAsync<Subscription>(
                showId, new PartitionKey(userId), cancellationToken: cancellationToken);
        }
        catch (CosmosException ex) when (ex.StatusCode == HttpStatusCode.NotFound)
        {
            // Already unsubscribed — idempotent no-op.
        }
    }

    public async Task<IReadOnlyList<NewEpisode>> GetNewEpisodesAsync(string userId, CancellationToken cancellationToken)
    {
        var subscriptions = await GetSubscriptionsAsync(userId, cancellationToken);

        var perShow = await Task.WhenAll(subscriptions.Select(async subscription =>
        {
            EpisodePage page;
            try
            {
                page = await episodeService.GetEpisodesAsync(
                    subscription.ShowId, continuationToken: null, NewEpisodesPerShow, cancellationToken);
            }
            catch (Exception ex) when (ex is HttpRequestException or XmlException or TaskCanceledException)
            {
                // One show's feed being unreachable, timing out, or malformed shouldn't fail "new
                // episodes" for every other subscription — treat it as "nothing new from this show"
                // instead. Deliberately narrow: Cosmos failures and other unexpected errors should
                // still surface rather than be silently swallowed here.
                return [];
            }

            var unseenChecks = await Task.WhenAll(page.Items.Select(async episode =>
            {
                var state = await episodeStateService.GetStateAsync(userId, episode.Id, cancellationToken);
                // "Unseen" includes auto-played episodes and restored-but-untouched ones (state
                // exists with Completed=false and no progress — the shape a Restore write leaves
                // behind), not just episodes with no state at all. Otherwise an episode the limit
                // job marked played, or one the user just restored, would silently vanish from this
                // list with no way to notice or undo it (#98/#99).
                var isUnseen = state is null || state.AutoPlayed || (!state.Completed && state.PositionSeconds == 0);
                return (episode, isUnseen, autoPlayed: state?.AutoPlayed ?? false);
            }));

            return unseenChecks.Where(x => x.isUnseen).Select(x => new NewEpisode(x.episode, x.autoPlayed)).ToList();
        }));

        return perShow
            .SelectMany(newEpisodes => newEpisodes)
            .OrderByDescending(newEpisode => newEpisode.Episode.PublishedAt)
            .ToList();
    }

    public async Task<IReadOnlyList<string>> GetDistinctSubscribedShowIdsAsync(CancellationToken cancellationToken)
    {
        var results = new List<string>();
        using var iterator = subscriptionsContainer.GetItemQueryIterator<string>(
            new QueryDefinition("SELECT DISTINCT VALUE c.ShowId FROM c"));

        while (iterator.HasMoreResults)
        {
            var page = await iterator.ReadNextAsync(cancellationToken);
            results.AddRange(page);
        }

        return results;
    }
}
