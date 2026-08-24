using System.Net;
using System.Net.Http.Json;
using Kuulla.Api.Models;
using Xunit;

namespace Kuulla.AppHost.Tests;

[Collection(AppHostCollection.Name)]
public class DynamicPlaylistAutoOrderingFlowTests(AppHostFixture fixture)
{
    // End-to-end against the real API + Cosmos emulator (no mocks): /dev/simulate-new-episodes
    // (#112) drives the same EpisodeService.CacheEpisodesAsync path a real feed refresh takes,
    // unlike /dev/seed-episodes which writes straight into Cosmos and skips the enforcement this
    // milestone adds. A new episode for a show referenced by a dynamic playlist's config should
    // land in the playlist, positioned ahead of an older episode from the same show.
    [Fact]
    public async Task SimulateNewEpisode_InsertsIntoDynamicPlaylistAheadOfOlderEpisode()
    {
        var showId = $"test-show-{Guid.NewGuid():N}";
        var oldEpisodeId = $"{showId}-old";
        var newEpisodeId = $"{showId}-new";
        var playlistId = $"test-playlist-{Guid.NewGuid():N}";

        using var client = fixture.CreateApiClient();
        var userId = $"test-user-{Guid.NewGuid():N}";

        await SeedShowAsync(client, showId);
        await SeedEpisodeAsync(client, showId, oldEpisodeId, DateTimeOffset.UtcNow.AddDays(-1));

        var playlist = new Playlist(
            playlistId,
            userId,
            Name: "Auto-Ordering Test Playlist",
            PlaylistType.Dynamic,
            Items: [new PlaylistItem(oldEpisodeId, showId, DateTimeOffset.UtcNow, Order: "m")],
            CreatedAt: DateTimeOffset.UtcNow,
            UpdatedAt: DateTimeOffset.UtcNow,
            DynamicConfig: new DynamicPlaylistConfig(ShowIds: [showId], MaxEpisodes: null, PriorityList: [showId]));
        var seedPlaylistResponse = await client.PostAsJsonAsync("/dev/seed-playlists", new List<Playlist> { playlist });
        Assert.Equal(HttpStatusCode.OK, seedPlaylistResponse.StatusCode);

        await SimulateNewEpisodeAsync(client, showId, newEpisodeId, DateTimeOffset.UtcNow);

        await AuthenticateAsync(client, userId);
        var detail = await client.GetFromJsonAsync<PlaylistDetail>($"/api/playlists/{playlistId}");

        Assert.NotNull(detail);
        Assert.Equal([newEpisodeId, oldEpisodeId], detail!.Items.Select(i => i.EpisodeId));
    }

    // Same simulate path, but with MaxEpisodes already at capacity — the newly-inserted episode
    // should push out the lowest-priority/oldest item rather than growing the playlist past its cap.
    [Fact]
    public async Task SimulateNewEpisode_EvictsOldestItemWhenAtCapacity()
    {
        var showId = $"test-show-{Guid.NewGuid():N}";
        var oldEpisodeId = $"{showId}-old";
        var midEpisodeId = $"{showId}-mid";
        var newEpisodeId = $"{showId}-new";
        var playlistId = $"test-playlist-{Guid.NewGuid():N}";

        using var client = fixture.CreateApiClient();
        var userId = $"test-user-{Guid.NewGuid():N}";

        await SeedShowAsync(client, showId);
        await SeedEpisodeAsync(client, showId, oldEpisodeId, DateTimeOffset.UtcNow.AddDays(-2));
        await SeedEpisodeAsync(client, showId, midEpisodeId, DateTimeOffset.UtcNow.AddDays(-1));

        var playlist = new Playlist(
            playlistId,
            userId,
            Name: "Auto-Ordering Eviction Test Playlist",
            PlaylistType.Dynamic,
            Items: [
                new PlaylistItem(midEpisodeId, showId, DateTimeOffset.UtcNow, Order: "m"),
                new PlaylistItem(oldEpisodeId, showId, DateTimeOffset.UtcNow, Order: "n"),
            ],
            CreatedAt: DateTimeOffset.UtcNow,
            UpdatedAt: DateTimeOffset.UtcNow,
            DynamicConfig: new DynamicPlaylistConfig(ShowIds: [showId], MaxEpisodes: 2, PriorityList: [showId]));
        var seedPlaylistResponse = await client.PostAsJsonAsync("/dev/seed-playlists", new List<Playlist> { playlist });
        Assert.Equal(HttpStatusCode.OK, seedPlaylistResponse.StatusCode);

        await SimulateNewEpisodeAsync(client, showId, newEpisodeId, DateTimeOffset.UtcNow);

        await AuthenticateAsync(client, userId);
        var detail = await client.GetFromJsonAsync<PlaylistDetail>($"/api/playlists/{playlistId}");

        Assert.NotNull(detail);
        Assert.Equal([newEpisodeId, midEpisodeId], detail!.Items.Select(i => i.EpisodeId));
    }

    private static async Task SeedShowAsync(HttpClient client, string showId)
    {
        var seedResponse = await client.PostAsJsonAsync("/dev/seed-show", new Show(
            showId,
            Title: "Auto-Ordering Test Show",
            Author: "Test Author",
            FeedUrl: "https://example.com/feed.xml",
            ArtworkUrl: null,
            Description: "Seeded directly for integration testing.",
            Categories: ["Technology"]));
        Assert.Equal(HttpStatusCode.OK, seedResponse.StatusCode);
    }

    private static async Task SeedEpisodeAsync(HttpClient client, string showId, string episodeId, DateTimeOffset publishedAt)
    {
        var episode = new Episode(
            episodeId,
            showId,
            Title: "Episode",
            PublishedAt: publishedAt,
            Duration: TimeSpan.FromMinutes(30),
            AudioUrl: $"https://example.com/{episodeId}.mp3",
            Description: null,
            BitrateKbps: null,
            FileSizeBytes: null);

        var seedResponse = await client.PostAsJsonAsync("/dev/seed-episodes", new List<Episode> { episode });
        Assert.Equal(HttpStatusCode.OK, seedResponse.StatusCode);
    }

    private static async Task SimulateNewEpisodeAsync(HttpClient client, string showId, string episodeId, DateTimeOffset publishedAt)
    {
        var episode = new Episode(
            episodeId,
            showId,
            Title: "Newly Published Episode",
            PublishedAt: publishedAt,
            Duration: TimeSpan.FromMinutes(30),
            AudioUrl: $"https://example.com/{episodeId}.mp3",
            Description: null,
            BitrateKbps: null,
            FileSizeBytes: null);

        var response = await client.PostAsJsonAsync(
            "/dev/simulate-new-episodes", new { ShowId = showId, Episodes = new List<Episode> { episode } });
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
    }

    // Mints a local test token for a fresh, unique user via /dev/test-token so each test's
    // playlists live in their own partition rather than colliding on "local-test-user".
    private static async Task AuthenticateAsync(HttpClient client, string userId)
    {
        var tokenResponse = await client.PostAsync($"/dev/test-token?sub={userId}", content: null);
        Assert.Equal(HttpStatusCode.OK, tokenResponse.StatusCode);
        var tokenPayload = await tokenResponse.Content.ReadFromJsonAsync<TestTokenResponse>();
        Assert.False(string.IsNullOrEmpty(tokenPayload?.Token));

        client.DefaultRequestHeaders.Authorization = new("Bearer", tokenPayload!.Token);
    }

    private sealed record TestTokenResponse(string Token);
}
