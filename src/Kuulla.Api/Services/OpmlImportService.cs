using Kuulla.Core.Services;

namespace Kuulla.Api.Services;

// One OPML entry that couldn't be imported, with a human-readable reason for the UI to show.
public record OpmlImportFailure(string FeedUrl, string Reason);

// Outcome of an OPML import. AddedShowIds backs the Added count and lets the endpoint fire the
// same post-subscribe unlistened-limit enforcement it runs for a single subscribe.
public record OpmlImportResult(
    IReadOnlyList<string> AddedShowIds,
    int AlreadySubscribed,
    IReadOnlyList<OpmlImportFailure> Failed)
{
    public int Added => AddedShowIds.Count;
}

public interface IOpmlImportService
{
    // Throws FormatException (mapped to 400 by the endpoint) when the document as a whole is
    // invalid; per-entry problems come back in the result's Failed list.
    Task<OpmlImportResult> ImportAsync(string userId, string opml, CancellationToken cancellationToken);
}

public class OpmlImportService(ISubscriptionService subscriptionService, IShowService showService)
    : IOpmlImportService
{
    // A 200-feed OPML shouldn't fan out 200 concurrent feed fetches + show creates at the
    // podcast hosts (or at Cosmos). Small enough to be polite, large enough that a big import
    // still finishes in a reasonable time.
    private const int MaxConcurrency = 6;

    public async Task<OpmlImportResult> ImportAsync(string userId, string opml, CancellationToken cancellationToken)
    {
        var feeds = OpmlParser.Parse(opml);

        var alreadySubscribedUrls = await ResolveExistingFeedUrlsAsync(userId, cancellationToken);

        var addedShowIds = new List<string>();
        var failed = new List<OpmlImportFailure>();
        var alreadySubscribed = 0;

        using var gate = new SemaphoreSlim(MaxConcurrency);
        var tasks = feeds.Select(async feed =>
        {
            // OpmlParser already returns feed URLs normalized, so this matches the same key
            // ResolveExistingFeedUrlsAsync built. Guarded anyway in case that ever changes.
            var normalized = FeedUrl.Normalize(feed.FeedUrl);
            if (alreadySubscribedUrls.Contains(normalized))
            {
                Interlocked.Increment(ref alreadySubscribed);
                return;
            }

            await gate.WaitAsync(cancellationToken);
            try
            {
                var feedShow = await showService.GetOrCreateByFeedUrlAsync(normalized, cancellationToken);
                if (feedShow is null)
                {
                    lock (failed)
                    {
                        failed.Add(new OpmlImportFailure(normalized, "The feed couldn't be fetched or read."));
                    }

                    return;
                }

                var show = feedShow.Show;

                // Seed the "Latest episode" sort key from the feed we just fetched — import
                // caches no episodes, so SubscribeAsync would otherwise stamp null and the show
                // would sort as "oldest" until a feed poll sweeps it (#501).
                var subscription = await subscriptionService.SubscribeAsync(
                    userId, show.Id, cancellationToken, feedShow.LatestEpisodePublishedAt);
                if (subscription is null)
                {
                    lock (failed)
                    {
                        failed.Add(new OpmlImportFailure(normalized, "The show couldn't be subscribed to."));
                    }

                    return;
                }

                lock (addedShowIds)
                {
                    addedShowIds.Add(show.Id);
                }
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                // One unreachable or misbehaving feed must not fail the whole import. The feed
                // fetch reaches out to an arbitrary third-party host through the resilience
                // pipeline, so beyond the HttpRequestException / XmlException that ShowService
                // already folds into a null it can still surface a Polly TimeoutRejectedException,
                // a BrokenCircuitException, an IOException mid-body, etc. Catch the lot here and
                // record this entry as failed rather than letting it bubble out of Task.WhenAll
                // and 500 the request.
                lock (failed)
                {
                    failed.Add(new OpmlImportFailure(normalized, "The feed couldn't be fetched or read."));
                }
            }
            finally
            {
                gate.Release();
            }
        });

        await Task.WhenAll(tasks);

        return new OpmlImportResult(addedShowIds, alreadySubscribed, failed);
    }

    // The user's current subscriptions, resolved to a set of normalized feed URLs. Cheap for the
    // common case (Subscription.FeedUrl is snapshotted on subscribe); only rows that predate that
    // field cost a point-read back to the shows container.
    private async Task<HashSet<string>> ResolveExistingFeedUrlsAsync(string userId, CancellationToken cancellationToken)
    {
        var subscriptions = await subscriptionService.GetSubscriptionsAsync(userId, cancellationToken);

        var resolved = await Task.WhenAll(subscriptions.Select(async subscription =>
            subscription.FeedUrl
            ?? await showService.TryGetFeedUrlAsync(subscription.ShowId, cancellationToken)));

        return resolved
            .Where(url => !string.IsNullOrEmpty(url))
            .Select(url => FeedUrl.Normalize(url!))
            .ToHashSet();
    }
}
