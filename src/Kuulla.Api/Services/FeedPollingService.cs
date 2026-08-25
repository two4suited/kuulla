using System.Xml;

namespace Kuulla.Api.Services;

public class FeedPollingService(
    ISubscriptionService subscriptionService,
    IShowService showService,
    IPodcastFeedClient feedClient,
    IEpisodeService episodeService,
    ILogger<FeedPollingService> logger) : IFeedPollingService
{
    // Capped in-flight refetches, matching the degree of parallelism EpisodeService.
    // CacheEpisodesAsync's own per-episode fan-out already uses — a subscriber base spanning
    // hundreds of shows shouldn't fire hundreds of concurrent outbound feed requests at once.
    private const int MaxDegreeOfParallelism = 10;

    public async Task PollOnceAsync(CancellationToken cancellationToken)
    {
        var showIds = await subscriptionService.GetDistinctSubscribedShowIdsAsync(cancellationToken);

        await Parallel.ForEachAsync(
            showIds,
            new ParallelOptions { MaxDegreeOfParallelism = MaxDegreeOfParallelism, CancellationToken = cancellationToken },
            (showId, ct) => new ValueTask(PollShowAsync(showId, ct)));
    }

    private async Task PollShowAsync(string showId, CancellationToken cancellationToken)
    {
        try
        {
            var show = await showService.GetByIdAsync(showId, cancellationToken);
            if (string.IsNullOrEmpty(show?.FeedUrl))
            {
                return;
            }

            var feed = await feedClient.FetchAsync(show.FeedUrl, cancellationToken);
            if (feed is not { Episodes.Count: > 0 })
            {
                return;
            }

            // Create-only under the hood (CacheEpisodesAsync), so re-polling a feed with no new
            // episodes is a cheap no-op — every item it sees already exists and is skipped on the
            // Cosmos Conflict path. New episodes flow through the same insertedEpisodes fan-out
            // GetEpisodesAsync's client-driven path already uses (unlistened-limit enforcement,
            // dynamic-playlist auto-insert), which is also the choke point #216's push-send hooks
            // into — no separate "is this new" bookkeeping needed here.
            await episodeService.CacheEpisodesAsync(showId, feed.Episodes, cancellationToken);
        }
        catch (Exception ex) when (ex is HttpRequestException or XmlException or TaskCanceledException)
        {
            // One show's feed being unreachable, timing out, or malformed shouldn't stop the rest
            // of the sweep — same narrow catch SubscriptionService.GetNewEpisodesAsync uses for the
            // same reason. Logged (unlike that request-scoped path) since nothing else observes an
            // unattended background sweep's failures.
            logger.LogWarning(ex, "Failed to poll feed for show {ShowId}", showId);
        }
    }
}
