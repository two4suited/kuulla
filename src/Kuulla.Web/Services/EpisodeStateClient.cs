using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using Kuulla.Web.Models;
using Kuulla.Web.Services.Sync;

namespace Kuulla.Web.Services;

public class EpisodeStateClient(KuullaApiClient apiClient)
{
    private const string DeviceId = "web";

    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    public async Task<IReadOnlyList<Episode>> GetNewEpisodesAsync(CancellationToken cancellationToken = default)
    {
        var client = await apiClient.CreateClientAsync();
        var response = await client.GetAsync("api/subscriptions/episodes", cancellationToken);
        if (response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden)
        {
            return [];
        }

        response.EnsureSuccessStatusCode();
        var results = await response.Content.ReadFromJsonAsync<List<Episode>>(JsonOptions, cancellationToken);
        return results ?? [];
    }

    public async Task<EpisodeState?> GetStateAsync(string episodeId, CancellationToken cancellationToken = default)
    {
        var client = await apiClient.CreateClientAsync();
        var response = await client.GetAsync($"api/episodes/{Uri.EscapeDataString(episodeId)}/state", cancellationToken);
        if (response.StatusCode == HttpStatusCode.NotFound)
        {
            return null;
        }

        response.EnsureSuccessStatusCode();
        return await response.Content.ReadFromJsonAsync<EpisodeState>(JsonOptions, cancellationToken);
    }

    public async Task<EpisodeState> UpdateStateAsync(
        string episodeId, string showId, int positionSeconds, bool completed, CancellationToken cancellationToken = default)
    {
        var client = await apiClient.CreateClientAsync();
        var body = new { ShowId = showId, PositionSeconds = positionSeconds, Completed = completed, DeviceId };
        var response = await client.PutAsJsonAsync(
            $"api/episodes/{Uri.EscapeDataString(episodeId)}/state", body, JsonOptions, cancellationToken);
        response.EnsureSuccessStatusCode();
        return (await response.Content.ReadFromJsonAsync<EpisodeState>(JsonOptions, cancellationToken))!;
    }

    public async Task<SyncCheckResult<EpisodeState>> SyncAsync(
        string localHash, DateTimeOffset lastSyncedAt, CancellationToken cancellationToken = default)
    {
        var client = await apiClient.CreateClientAsync();
        var body = new
        {
            DeviceId,
            LastSyncedAt = lastSyncedAt,
            LocalHash = localHash,
            Changes = Array.Empty<object>(),
        };
        var response = await client.PostAsJsonAsync("api/sync/episodes", body, JsonOptions, cancellationToken);
        response.EnsureSuccessStatusCode();
        var result = await response.Content.ReadFromJsonAsync<SyncEpisodesResponse>(JsonOptions, cancellationToken);
        return new SyncCheckResult<EpisodeState>(result!.ServerChanges, result.SyncedAt, result.Hash);
    }

    private sealed record SyncEpisodesResponse(IReadOnlyList<EpisodeState> ServerChanges, DateTimeOffset SyncedAt, string Hash);
}
