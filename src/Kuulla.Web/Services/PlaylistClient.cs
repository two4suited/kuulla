using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using Kuulla.Web.Models;

namespace Kuulla.Web.Services;

public class PlaylistClient(KuullaApiClient apiClient)
{
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
}
