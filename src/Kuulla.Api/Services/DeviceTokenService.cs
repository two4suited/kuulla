using System.Net;
using Microsoft.Azure.Cosmos;
using Microsoft.Extensions.DependencyInjection;
using Kuulla.Api.Models;

namespace Kuulla.Api.Services;

public class DeviceTokenService(
    [FromKeyedServices("devicetokens")] Container deviceTokensContainer) : IDeviceTokenService
{
    public async Task<DeviceToken> RegisterAsync(
        string userId, string deviceId, string apnsToken, DevicePlatform platform, CancellationToken cancellationToken)
    {
        // Upsert on the composite id rather than Create-then-handle-Conflict (SubscriptionService's
        // pattern): a re-registration should overwrite the stored ApnsToken/UpdatedAt (Apple can
        // reissue a device's token), not preserve the original like Subscription's SubscribedAt does.
        var token = DeviceToken.Create(userId, deviceId, apnsToken, platform);
        var response = await deviceTokensContainer.UpsertItemAsync(
            token, new PartitionKey(userId), cancellationToken: cancellationToken);
        return response.Resource;
    }

    public async Task UnregisterAsync(string userId, string deviceId, CancellationToken cancellationToken)
    {
        try
        {
            await deviceTokensContainer.DeleteItemAsync<DeviceToken>(
                DeviceToken.BuildId(userId, deviceId), new PartitionKey(userId), cancellationToken: cancellationToken);
        }
        catch (CosmosException ex) when (ex.StatusCode == HttpStatusCode.NotFound)
        {
            // Already unregistered — idempotent no-op, matching SubscriptionService.UnsubscribeAsync.
        }
    }

    public async Task<IReadOnlyList<DeviceToken>> GetTokensForUserAsync(string userId, CancellationToken cancellationToken)
    {
        var results = new List<DeviceToken>();
        using var iterator = deviceTokensContainer.GetItemQueryIterator<DeviceToken>(
            new QueryDefinition("SELECT * FROM c"),
            requestOptions: new QueryRequestOptions { PartitionKey = new PartitionKey(userId) });

        while (iterator.HasMoreResults)
        {
            var page = await iterator.ReadNextAsync(cancellationToken);
            results.AddRange(page);
        }

        return results;
    }
}
