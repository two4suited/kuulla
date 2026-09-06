using Kuulla.Core.Models;

namespace Kuulla.Core.Services;

public interface ISubscriptionService
{
    Task<IReadOnlyList<Subscription>> GetSubscriptionsAsync(string userId, CancellationToken cancellationToken);

    Task<Subscription?> SubscribeAsync(string userId, string showId, CancellationToken cancellationToken);

    Task UnsubscribeAsync(string userId, string showId, CancellationToken cancellationToken);

    Task<IReadOnlyList<NewEpisode>> GetNewEpisodesAsync(string userId, CancellationToken cancellationToken);

    // Cross-partition (subscriptions are partitioned by UserId, and this deliberately spans every
    // user) — the set of shows anyone is subscribed to, for the feed-polling background job to
    // walk. Off the hot path (runs on a timer, not per-request), so the cross-partition query cost
    // is acceptable here the way it isn't for a request-scoped read.
    Task<IReadOnlyList<string>> GetDistinctSubscribedShowIdsAsync(CancellationToken cancellationToken);
}
