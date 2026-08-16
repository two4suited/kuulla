using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using Kuulla.Web.Models;

namespace Kuulla.Web.Services;

public class PodcastCatalogClient(KuullaApiClient apiClient)
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    public async Task<IReadOnlyList<Show>> SearchShowsAsync(string query, CancellationToken cancellationToken = default)
    {
        var client = apiClient.CreateClient();
        var url = $"api/shows/search?q={Uri.EscapeDataString(query)}";
        var results = await client.GetFromJsonAsync<List<Show>>(url, JsonOptions, cancellationToken);
        return results ?? [];
    }

    public async Task<Show?> GetShowAsync(string id, CancellationToken cancellationToken = default)
    {
        var client = apiClient.CreateClient();
        var response = await client.GetAsync($"api/shows/{Uri.EscapeDataString(id)}", cancellationToken);
        if (response.StatusCode == HttpStatusCode.NotFound)
        {
            return null;
        }

        response.EnsureSuccessStatusCode();
        return await response.Content.ReadFromJsonAsync<Show>(JsonOptions, cancellationToken);
    }

    public async Task<EpisodePage> GetEpisodesAsync(
        string showId,
        string? continuationToken,
        int pageSize,
        CancellationToken cancellationToken = default)
    {
        var client = apiClient.CreateClient();
        var url = $"api/shows/{Uri.EscapeDataString(showId)}/episodes?pageSize={pageSize}";
        if (continuationToken is not null)
        {
            url += $"&continuationToken={Uri.EscapeDataString(continuationToken)}";
        }

        var page = await client.GetFromJsonAsync<EpisodePage>(url, JsonOptions, cancellationToken);
        return page ?? new EpisodePage([], null);
    }

    public async Task<Episode?> GetEpisodeAsync(string showId, string episodeId, CancellationToken cancellationToken = default)
    {
        var client = apiClient.CreateClient();
        var response = await client.GetAsync(
            $"api/shows/{Uri.EscapeDataString(showId)}/episodes/{Uri.EscapeDataString(episodeId)}", cancellationToken);
        if (response.StatusCode == HttpStatusCode.NotFound)
        {
            return null;
        }

        response.EnsureSuccessStatusCode();
        return await response.Content.ReadFromJsonAsync<Episode>(JsonOptions, cancellationToken);
    }
}
