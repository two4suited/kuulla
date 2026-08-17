using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using Kuulla.Web.Models;

namespace Kuulla.Web.Services;

public class SubscriptionClient(KuullaApiClient apiClient)
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    public async Task<IReadOnlyList<Subscription>> GetSubscriptionsAsync(CancellationToken cancellationToken = default)
    {
        var client = await apiClient.CreateClientAsync();
        var response = await client.GetAsync("api/subscriptions", cancellationToken);
        if (response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden)
        {
            return [];
        }

        response.EnsureSuccessStatusCode();
        var results = await response.Content.ReadFromJsonAsync<List<Subscription>>(JsonOptions, cancellationToken);
        return results ?? [];
    }

    public async Task<Subscription?> SubscribeAsync(string showId, CancellationToken cancellationToken = default)
    {
        var client = await apiClient.CreateClientAsync();
        var response = await client.PostAsJsonAsync("api/subscriptions", new { ShowId = showId }, JsonOptions, cancellationToken);
        response.EnsureSuccessStatusCode();
        return await response.Content.ReadFromJsonAsync<Subscription>(JsonOptions, cancellationToken);
    }

    public async Task UnsubscribeAsync(string showId, CancellationToken cancellationToken = default)
    {
        var client = await apiClient.CreateClientAsync();
        var response = await client.DeleteAsync($"api/subscriptions/{Uri.EscapeDataString(showId)}", cancellationToken);
        response.EnsureSuccessStatusCode();
    }
}
