using Kuulla.Api.Models;

namespace Kuulla.Api.Services;

public interface ISubscriptionService
{
    Task<IReadOnlyList<Subscription>> GetSubscriptionsAsync(string userId, CancellationToken cancellationToken);

    Task<Subscription?> SubscribeAsync(string userId, string showId, CancellationToken cancellationToken);

    Task UnsubscribeAsync(string userId, string showId, CancellationToken cancellationToken);
}
