using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using Kuulla.Web.Models;
using Kuulla.Web.Services.Sync;

namespace Kuulla.Web.Services;

public class EpisodeStateClient(KuullaApiClient apiClient)
{
    // Every web client reports the same origin id (there's no per-browser identity today), so a
    // stored EpisodeState whose DeviceId isn't this value was last written by something other
    // than a browser. Public so the cross-device handoff check (#244) can compare against it.
    public const string WebDeviceId = "web";

    // Mirrors SubscriptionService.NewEpisodesPerShow on the API — the new-episodes endpoint
    // this caps how many episodes it returns per show, so an unplayed count sitting at this
    // cap means "at least this many," not necessarily exact.
    public const int NewEpisodesPerShowLimit = 10;

    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    public async Task<IReadOnlyList<NewEpisode>> GetNewEpisodesAsync(CancellationToken cancellationToken = default)
    {
        var client = await apiClient.CreateClientAsync();
        var response = await client.GetAsync("api/subscriptions/episodes", cancellationToken);
        if (response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden)
        {
            return [];
        }

        response.EnsureSuccessStatusCode();
        var results = await response.Content.ReadFromJsonAsync<List<NewEpisode>>(JsonOptions, cancellationToken);
        return results ?? [];
    }

    // Shared by Library and Subscriptions so both pages' unplayed badges stay in sync.
    public async Task<IReadOnlyDictionary<string, UnplayedCount>> GetUnplayedCountsByShowAsync(CancellationToken cancellationToken = default)
    {
        var newEpisodes = await GetNewEpisodesAsync(cancellationToken);
        var counts = new Dictionary<string, UnplayedCount>();
        foreach (var group in newEpisodes.GroupBy(e => e.Episode.ShowId))
        {
            // Auto-played episodes are "unseen" but already marked played, so they shouldn't
            // count toward an "unplayed" badge — mirrors the New Episodes header badge.
            var count = group.Count(e => !e.AutoPlayed);
            if (count > 0)
            {
                // HitCap is based on the *filtered* count, not the raw per-show page size: the
                // unlistened-episode-limit enforcement job auto-marks every episode beyond a user's
                // limit as played across a show's entire back catalog, not just this fetched page.
                // So once this page contains any auto-played episode, every genuinely-unplayed
                // episode for the show is guaranteed to already be in it — the raw count hitting the
                // cap carries no extra information there. The only case where more unplayed episodes
                // could exist beyond this page is when the whole page is unplayed (nothing to
                // auto-play within it), i.e. count == raw group size == cap.
                counts[group.Key] = new UnplayedCount(count, count >= NewEpisodesPerShowLimit);
            }
        }

        return counts;
    }

    // Shows the user has an in-progress episode for — drives the "in progress" badge on the
    // Library and Subscriptions grids, alongside the unplayed-count badge.
    public async Task<IReadOnlySet<string>> GetInProgressShowIdsAsync(CancellationToken cancellationToken = default)
    {
        var client = await apiClient.CreateClientAsync();
        var response = await client.GetAsync("api/episodes/in-progress-shows", cancellationToken);
        if (response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden)
        {
            return new HashSet<string>();
        }

        response.EnsureSuccessStatusCode();
        var results = await response.Content.ReadFromJsonAsync<List<string>>(JsonOptions, cancellationToken);
        return results is null ? new HashSet<string>() : new HashSet<string>(results);
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

    public async Task<IReadOnlyDictionary<string, EpisodeState>> GetStatesAsync(
        IReadOnlyList<string> episodeIds, CancellationToken cancellationToken = default)
    {
        if (episodeIds.Count == 0)
        {
            return new Dictionary<string, EpisodeState>();
        }

        var client = await apiClient.CreateClientAsync();
        var body = new { EpisodeIds = episodeIds };
        var response = await client.PostAsJsonAsync("api/episodes/states", body, JsonOptions, cancellationToken);
        response.EnsureSuccessStatusCode();
        var results = await response.Content.ReadFromJsonAsync<Dictionary<string, EpisodeState>>(JsonOptions, cancellationToken);
        return results ?? new Dictionary<string, EpisodeState>();
    }

    public async Task<EpisodeState> UpdateStateAsync(
        string episodeId, string showId, int positionSeconds, bool completed, CancellationToken cancellationToken = default)
    {
        var client = await apiClient.CreateClientAsync();
        var body = new { ShowId = showId, PositionSeconds = positionSeconds, Completed = completed, DeviceId = WebDeviceId };
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
            DeviceId = WebDeviceId,
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

// Per-show unplayed count, plus whether that count hit the API's page cap — if so, the fetched
// page may not contain every genuinely-unplayed episode for the show, so callers should render
// "{Count}+" rather than the bare Count even though it's exactly at the cap.
public sealed record UnplayedCount(int Count, bool HitCap);
