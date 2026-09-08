using Kuulla.Core.Models;

namespace Kuulla.Core.Services;

public interface ISubscriptionService
{
    Task<IReadOnlyList<Subscription>> GetSubscriptionsAsync(string userId, CancellationToken cancellationToken);

    // latestEpisodePublishedAtHint lets a caller that already has the show's feed in hand (OPML
    // import) seed the "Latest episode" sort key (#438, #501) without waiting for a feed poll to
    // cache episodes. The stamped value is the newer of this hint and whatever's already cached.
    Task<Subscription?> SubscribeAsync(
        string userId,
        string showId,
        CancellationToken cancellationToken,
        DateTimeOffset? latestEpisodePublishedAtHint = null);

    Task UnsubscribeAsync(string userId, string showId, CancellationToken cancellationToken);

    Task<IReadOnlyList<NewEpisode>> GetNewEpisodesAsync(string userId, CancellationToken cancellationToken);

    // Cross-partition (subscriptions are partitioned by UserId, and this deliberately spans every
    // user) — the set of shows anyone is subscribed to, for the feed-polling background job to
    // walk. Off the hot path (runs on a timer, not per-request), so the cross-partition query cost
    // is acceptable here the way it isn't for a request-scoped read.
    Task<IReadOnlyList<string>> GetDistinctSubscribedShowIdsAsync(CancellationToken cancellationToken);
}
