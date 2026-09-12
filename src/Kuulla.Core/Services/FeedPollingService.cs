using System.Diagnostics;
using System.Xml;
using Microsoft.Azure.Cosmos;

namespace Kuulla.Core.Services;

public class FeedPollingService(
    ISubscriptionService subscriptionService,
    IShowService showService,
    IPodcastFeedClient feedClient,
    IEpisodeService episodeService,
    ILogger<FeedPollingService> logger) : IFeedPollingService
{
    // Bounds the *outer* degree of concurrency: each show polled here can itself spawn up to
    // CacheEpisodesAsync's own internal fan-out (5, lowered from 20 in #558) worth of concurrent
    // Cosmos writes/enforcement calls, so this level keeps total concurrent outbound HTTP + Cosmos
    // load reasonable rather than multiplying the two together.
    private const int MaxDegreeOfParallelism = 5;

    public async Task PollOnceAsync(CancellationToken cancellationToken)
    {
        var stopwatch = Stopwatch.StartNew();
        var showIds = await subscriptionService.GetDistinctSubscribedShowIdsAsync(cancellationToken);

        // A scheduled job (Kuulla.FeedPoller) is otherwise unobserved — nothing tails its output —
        // so bookend the sweep with a summary line each. "one sweep per interval, N shows, M
        // failed" is the signal used to confirm the cutover in #416 without wading through the
        // per-request HTTP-client noise.
        logger.LogInformation("Feed-poll sweep starting: {ShowCount} subscribed show(s)", showIds.Count);

        var failures = 0;
        await Parallel.ForEachAsync(
            showIds,
            new ParallelOptions { MaxDegreeOfParallelism = MaxDegreeOfParallelism, CancellationToken = cancellationToken },
            async (showId, ct) =>
            {
                if (!await PollShowAsync(showId, ct))
                {
                    Interlocked.Increment(ref failures);
                }
            });

        logger.LogInformation(
            "Feed-poll sweep complete: {ShowCount} show(s), {FailureCount} unreachable/malformed, {ElapsedMs}ms",
            showIds.Count, failures, stopwatch.ElapsedMilliseconds);
    }

    // Returns false only when the feed itself couldn't be fetched or parsed (counted toward the
    // sweep's failure total); an intentional skip (no/invalid FeedUrl, empty feed) returns true.
    private async Task<bool> PollShowAsync(string showId, CancellationToken cancellationToken)
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

                return true;
            }

            var feed = await feedClient.FetchAsync(show.FeedUrl, cancellationToken);
            if (feed is not { Episodes.Count: > 0 })
            {
                return true;
            }

            // Create-only under the hood (CacheEpisodesAsync), so re-polling a feed with no new
            // episodes is a cheap no-op — every item it sees already exists and is skipped on the
            // Cosmos Conflict path. New episodes flow through the same insertedEpisodes fan-out
            // GetEpisodesAsync's client-driven path already uses (unlistened-limit enforcement,
            // dynamic-playlist auto-insert), which is also the choke point #216's push-send hooks
            // into — no separate "is this new" bookkeeping needed here.
            await episodeService.CacheEpisodesAsync(showId, feed.Episodes, cancellationToken);
            return true;
        }
        catch (Exception ex) when (
            ex is HttpRequestException or XmlException or CosmosException
            || (ex is TaskCanceledException && !cancellationToken.IsCancellationRequested))
        {
            // One show's feed being unreachable, timing out, malformed, or hitting a Cosmos error
            // (e.g. a 429 that exhausts CacheEpisodesAsync's own retries, #558) shouldn't stop the
            // rest of the sweep — same narrow catch SubscriptionService.GetNewEpisodesAsync uses for
            // the same reason. Logged (unlike that request-scoped path) since nothing else observes
            // an unattended background sweep's failures.
            //
            // TaskCanceledException is only caught when it's NOT caused by our own
            // cancellationToken (e.g. an HttpClient-internal per-request timeout) — a real
            // shutdown cancellation needs to propagate as OperationCanceledException so
            // BackgroundService's normal shutdown handling applies instead of being logged as a
            // per-show failure.
            logger.LogWarning(ex, "Failed to poll feed for show {ShowId}", showId);
            return false;
        }
    }
}
