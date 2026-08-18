using System.Net.Http.Json;
using System.Text.Json;
using Kuulla.Web.Models;

namespace Kuulla.Web.Services;

public class SettingsClient(KuullaApiClient apiClient)
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    public async Task<UserSettings> GetSettingsAsync(CancellationToken cancellationToken = default)
    {
        var client = await apiClient.CreateClientAsync();
        var response = await client.GetAsync("api/settings", cancellationToken);
        response.EnsureSuccessStatusCode();
        return (await response.Content.ReadFromJsonAsync<UserSettings>(JsonOptions, cancellationToken))!;
    }

    public async Task<UserSettings> UpdateUnlistenedEpisodeCountAsync(
        UnlistenedEpisodeCount unlistenedEpisodeCount, CancellationToken cancellationToken = default)
    {
        var client = await apiClient.CreateClientAsync();
        var response = await client.PutAsJsonAsync(
            "api/settings", new { UnlistenedEpisodeCount = unlistenedEpisodeCount }, JsonOptions, cancellationToken);
        response.EnsureSuccessStatusCode();
        return (await response.Content.ReadFromJsonAsync<UserSettings>(JsonOptions, cancellationToken))!;
    }

    public async Task<ShowSettings> GetShowSettingsAsync(string showId, CancellationToken cancellationToken = default)
    {
        var client = await apiClient.CreateClientAsync();
        var response = await client.GetAsync($"api/settings/shows/{Uri.EscapeDataString(showId)}", cancellationToken);
        response.EnsureSuccessStatusCode();
        return (await response.Content.ReadFromJsonAsync<ShowSettings>(JsonOptions, cancellationToken))!;
    }

    public async Task<ShowSettings> UpdateShowUnlistenedEpisodeCountAsync(
        string showId, UnlistenedEpisodeCount? unlistenedEpisodeCount, CancellationToken cancellationToken = default)
    {
        var client = await apiClient.CreateClientAsync();
        var response = await client.PutAsJsonAsync(
            $"api/settings/shows/{Uri.EscapeDataString(showId)}",
            new { UnlistenedEpisodeCount = unlistenedEpisodeCount }, JsonOptions, cancellationToken);
        response.EnsureSuccessStatusCode();
        return (await response.Content.ReadFromJsonAsync<ShowSettings>(JsonOptions, cancellationToken))!;
    }
}
