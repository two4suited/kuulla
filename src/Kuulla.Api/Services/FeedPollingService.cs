using System.Xml;

namespace Kuulla.Api.Services;

public class FeedPollingService(
    ISubscriptionService subscriptionService,
    IShowService showService,
    IPodcastFeedClient feedClient,
    IEpisodeService episodeService,
    ILogger<FeedPollingService> logger) : IFeedPollingService
{
    // Deliberately lower than EpisodeService.CacheEpisodesAsync's own internal fan-out (20): each
    // show polled here can itself spawn up to 20 concurrent Cosmos writes/enforcement calls inside
    // CacheEpisodesAsync, so this level bounds the *outer* degree to keep total concurrent
    // outbound HTTP + Cosmos load reasonable rather than multiplying the two together.
    private const int MaxDegreeOfParallelism = 5;

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
            // Absolute-URI check (not just non-empty) so a malformed FeedUrl is isolated to this
            // show here rather than reaching HttpClient and throwing UriFormatException, which
            // isn't in the catch below and would otherwise cancel every other show still in
            // flight in the same Parallel.ForEachAsync batch.
            if (string.IsNullOrEmpty(show?.FeedUrl) || !Uri.TryCreate(show.FeedUrl, UriKind.Absolute, out _))
            {
                if (show is not null)
                {
                    logger.LogWarning("Show {ShowId} has an invalid FeedUrl {FeedUrl} — skipping", showId, show.FeedUrl);
                }

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
        catch (Exception ex) when (
            ex is HttpRequestException or XmlException || (ex is TaskCanceledException && !cancellationToken.IsCancellationRequested))
        {
            // One show's feed being unreachable, timing out, or malformed shouldn't stop the rest
            // of the sweep — same narrow catch SubscriptionService.GetNewEpisodesAsync uses for the
            // same reason. Logged (unlike that request-scoped path) since nothing else observes an
            // unattended background sweep's failures.
            //
            // TaskCanceledException is only caught when it's NOT caused by our own
            // cancellationToken (e.g. an HttpClient-internal per-request timeout) — a real
            // shutdown cancellation needs to propagate as OperationCanceledException so
            // BackgroundService's normal shutdown handling applies instead of being logged as a
            // per-show failure.
            logger.LogWarning(ex, "Failed to poll feed for show {ShowId}", showId);
        }
    }
}
