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

    // Uploads an OPML file to the bulk-import endpoint. Throws OpmlImportException (with a
    // user-facing message) for a rejected file — too large, or not a readable OPML document.
    public async Task<OpmlImportResult> ImportOpmlAsync(Stream opml, string fileName, CancellationToken cancellationToken = default)
    {
        var client = await apiClient.CreateClientAsync();

        using var content = new MultipartFormDataContent();
        using var fileContent = new StreamContent(opml);
        content.Add(fileContent, "file", fileName);

        var response = await client.PostAsync("api/subscriptions/import", content, cancellationToken);

        if (response.StatusCode == HttpStatusCode.RequestEntityTooLarge)
        {
            throw new OpmlImportException("That file is larger than the 5 MB limit.");
        }

        if (response.StatusCode == HttpStatusCode.BadRequest)
        {
            throw new OpmlImportException("That file couldn't be read as an OPML subscription list.");
        }

        response.EnsureSuccessStatusCode();
        return await response.Content.ReadFromJsonAsync<OpmlImportResult>(JsonOptions, cancellationToken)
            ?? new OpmlImportResult(0, 0, []);
    }
}

public class OpmlImportException(string message) : Exception(message);
