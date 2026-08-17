using System.Net;
using Microsoft.Azure.Cosmos;
using Kuulla.Api.Models;

namespace Kuulla.Api.Services;

public class SubscriptionService(
    [FromKeyedServices("subscriptions")] Container subscriptionsContainer,
    IShowService showService) : ISubscriptionService
{
    public async Task<IReadOnlyList<Subscription>> GetSubscriptionsAsync(string userId, CancellationToken cancellationToken)
    {
        var results = new List<Subscription>();
        var iterator = subscriptionsContainer.GetItemQueryIterator<Subscription>(
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

        var subscription = new Subscription(
            showId,
            userId,
            showId,
            show.Title,
            show.Author,
            show.ArtworkUrl,
            DateTimeOffset.UtcNow);

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
}
