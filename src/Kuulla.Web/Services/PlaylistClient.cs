using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using Kuulla.Web.Models;
using Kuulla.Web.Services.Sync;

namespace Kuulla.Web.Services;

public class PlaylistClient(KuullaApiClient apiClient)
{
    private const string DeviceId = "web";

    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    public async Task<IReadOnlyList<Playlist>> GetPlaylistsAsync(CancellationToken cancellationToken = default)
    {
        var client = await apiClient.CreateClientAsync();
        var response = await client.GetAsync("api/playlists", cancellationToken);
        if (response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden)
        {
            return [];
        }

        response.EnsureSuccessStatusCode();
        var results = await response.Content.ReadFromJsonAsync<List<Playlist>>(JsonOptions, cancellationToken);
        return results ?? [];
    }

    public async Task<Playlist> CreatePlaylistAsync(string name, CancellationToken cancellationToken = default)
    {
        var client = await apiClient.CreateClientAsync();
        var response = await client.PostAsJsonAsync("api/playlists", new { Name = name }, JsonOptions, cancellationToken);
        response.EnsureSuccessStatusCode();
        return (await response.Content.ReadFromJsonAsync<Playlist>(JsonOptions, cancellationToken))!;
    }

    public async Task<Playlist> CreateDynamicPlaylistAsync(
        string name, DynamicPlaylistConfig config, CancellationToken cancellationToken = default)
    {
        var client = await apiClient.CreateClientAsync();
        var body = new { Name = name, Type = PlaylistType.Dynamic, DynamicConfig = config };
        var response = await client.PostAsJsonAsync("api/playlists", body, JsonOptions, cancellationToken);
        response.EnsureSuccessStatusCode();
        return (await response.Content.ReadFromJsonAsync<Playlist>(JsonOptions, cancellationToken))!;
    }

    public async Task<Playlist?> UpdateDynamicPlaylistConfigAsync(
        string id, DynamicPlaylistConfig config, CancellationToken cancellationToken = default)
    {
        var client = await apiClient.CreateClientAsync();
        var response = await client.PutAsJsonAsync(
            $"api/playlists/{Uri.EscapeDataString(id)}/config", config, JsonOptions, cancellationToken);
        if (response.StatusCode == HttpStatusCode.NotFound)
        {
            return null;
        }

        response.EnsureSuccessStatusCode();
        return await response.Content.ReadFromJsonAsync<Playlist>(JsonOptions, cancellationToken);
    }

    public async Task<PlaylistDetail?> GetPlaylistDetailAsync(string id, CancellationToken cancellationToken = default)
    {
        var client = await apiClient.CreateClientAsync();
        var response = await client.GetAsync($"api/playlists/{Uri.EscapeDataString(id)}", cancellationToken);
        if (response.StatusCode == HttpStatusCode.NotFound)
        {
            return null;
        }

        response.EnsureSuccessStatusCode();
        return await response.Content.ReadFromJsonAsync<PlaylistDetail>(JsonOptions, cancellationToken);
    }

    public async Task<Playlist?> RenamePlaylistAsync(string id, string name, CancellationToken cancellationToken = default)
    {
        var client = await apiClient.CreateClientAsync();
        var response = await client.PutAsJsonAsync(
            $"api/playlists/{Uri.EscapeDataString(id)}", new { Name = name }, JsonOptions, cancellationToken);
        if (response.StatusCode == HttpStatusCode.NotFound)
        {
            return null;
        }

        response.EnsureSuccessStatusCode();
        return await response.Content.ReadFromJsonAsync<Playlist>(JsonOptions, cancellationToken);
    }

    public async Task DeletePlaylistAsync(string id, CancellationToken cancellationToken = default)
    {
        var client = await apiClient.CreateClientAsync();
        var response = await client.DeleteAsync($"api/playlists/{Uri.EscapeDataString(id)}", cancellationToken);
        response.EnsureSuccessStatusCode();
    }

    public async Task<Playlist?> AddItemAsync(
        string id, string episodeId, string showId, CancellationToken cancellationToken = default)
    {
        var client = await apiClient.CreateClientAsync();
        var body = new { EpisodeId = episodeId, ShowId = showId };
        var response = await client.PostAsJsonAsync($"api/playlists/{Uri.EscapeDataString(id)}/items", body, JsonOptions, cancellationToken);
        if (response.StatusCode == HttpStatusCode.NotFound)
        {
            return null;
        }

        response.EnsureSuccessStatusCode();
        return await response.Content.ReadFromJsonAsync<Playlist>(JsonOptions, cancellationToken);
    }

    public async Task<Playlist?> RemoveItemAsync(string id, string episodeId, CancellationToken cancellationToken = default)
    {
        var client = await apiClient.CreateClientAsync();
        var response = await client.DeleteAsync(
            $"api/playlists/{Uri.EscapeDataString(id)}/items/{Uri.EscapeDataString(episodeId)}", cancellationToken);
        if (response.StatusCode == HttpStatusCode.NotFound)
        {
            return null;
        }

        response.EnsureSuccessStatusCode();
        return await response.Content.ReadFromJsonAsync<Playlist>(JsonOptions, cancellationToken);
    }

    public async Task<Playlist?> ReorderItemAsync(
        string id,
        string episodeId,
        string? beforeEpisodeId,
        string? afterEpisodeId,
        CancellationToken cancellationToken = default)
    {
        var client = await apiClient.CreateClientAsync();
        var body = new { BeforeEpisodeId = beforeEpisodeId, AfterEpisodeId = afterEpisodeId };
        var response = await client.PutAsJsonAsync(
            $"api/playlists/{Uri.EscapeDataString(id)}/items/{Uri.EscapeDataString(episodeId)}/order",
            body, JsonOptions, cancellationToken);
        if (response.StatusCode == HttpStatusCode.NotFound)
        {
            return null;
        }

        response.EnsureSuccessStatusCode();
        return await response.Content.ReadFromJsonAsync<Playlist>(JsonOptions, cancellationToken);
    }

    // Empty-changes poll for SyncStatusService<Playlist> (#113) — mirrors EpisodeStateClient.
    // SyncAsync exactly, an empty-changes call to POST /api/sync/playlists that only asks "did
    // anything change server-side since lastSyncedAt/localHash", never pushing a local write.
    public async Task<SyncCheckResult<Playlist>> SyncAsync(
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
        var response = await client.PostAsJsonAsync("api/sync/playlists", body, JsonOptions, cancellationToken);
        response.EnsureSuccessStatusCode();
        var result = await response.Content.ReadFromJsonAsync<SyncPlaylistsResponse>(JsonOptions, cancellationToken);
        return new SyncCheckResult<Playlist>(result!.ServerChanges, result.SyncedAt, result.Hash);
    }

    private sealed record SyncPlaylistsResponse(IReadOnlyList<Playlist> ServerChanges, DateTimeOffset SyncedAt, string Hash);
}
