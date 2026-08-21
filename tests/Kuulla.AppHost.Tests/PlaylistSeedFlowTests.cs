using System.Net;
using System.Net.Http.Json;
using Kuulla.Api.Models;
using Xunit;

namespace Kuulla.AppHost.Tests;

[Collection(AppHostCollection.Name)]
public class PlaylistSeedFlowTests(AppHostFixture fixture)
{
    // End-to-end against the real API + Cosmos emulator (no mocks): the /dev/seed-playlists hook
    // (#249) lets a test drop a manual playlist with items straight into Cosmos, rather than
    // replaying POST /api/playlists + POST /api/playlists/{id}/items one call at a time.
    [Fact]
    public async Task SeedManualPlaylist_IsReturnedByListAndDetailEndpoints()
    {
        var showId = $"test-show-{Guid.NewGuid():N}";
        var episodeId = $"{showId}-ep-0";
        var playlistId = $"test-playlist-{Guid.NewGuid():N}";

        using var client = fixture.CreateApiClient();
        var userId = $"test-user-{Guid.NewGuid():N}";

        await SeedShowAsync(client, showId);
        await SeedEpisodeAsync(client, showId, episodeId);

        var playlist = new Playlist(
            playlistId,
            userId,
            Name: "Seeded Manual Playlist",
            PlaylistType.Manual,
            Items: [new PlaylistItem(episodeId, showId, DateTimeOffset.UtcNow, Order: "m")],
            CreatedAt: DateTimeOffset.UtcNow,
            UpdatedAt: DateTimeOffset.UtcNow);

        var seedResponse = await client.PostAsJsonAsync("/dev/seed-playlists", new List<Playlist> { playlist });
        Assert.Equal(HttpStatusCode.OK, seedResponse.StatusCode);

        await AuthenticateAsync(client, userId);

        var list = await client.GetFromJsonAsync<List<Playlist>>("/api/playlists");
        Assert.Contains(list!, p => p.Id == playlistId && p.Name == "Seeded Manual Playlist");

        var detail = await client.GetFromJsonAsync<PlaylistDetail>($"/api/playlists/{playlistId}");
        Assert.NotNull(detail);
        Assert.Single(detail!.Items);
        Assert.Equal(episodeId, detail.Items[0].EpisodeId);
    }

    // Same hook, but for a Dynamic playlist — DynamicConfig must round-trip through Cosmos
    // untouched since it drives the Dynamic Playlist Auto-Ordering milestone.
    [Fact]
    public async Task SeedDynamicPlaylist_PreservesDynamicConfig()
    {
        var showId = $"test-show-{Guid.NewGuid():N}";
        var playlistId = $"test-playlist-{Guid.NewGuid():N}";

        using var client = fixture.CreateApiClient();
        var userId = $"test-user-{Guid.NewGuid():N}";

        await SeedShowAsync(client, showId);

        var playlist = new Playlist(
            playlistId,
            userId,
            Name: "Seeded Dynamic Playlist",
            PlaylistType.Dynamic,
            Items: [],
            CreatedAt: DateTimeOffset.UtcNow,
            UpdatedAt: DateTimeOffset.UtcNow,
            DynamicConfig: new DynamicPlaylistConfig(
                ShowIds: [showId],
                MaxEpisodes: 10,
                PriorityList: [showId]));

        var seedResponse = await client.PostAsJsonAsync("/dev/seed-playlists", new List<Playlist> { playlist });
        Assert.Equal(HttpStatusCode.OK, seedResponse.StatusCode);

        await AuthenticateAsync(client, userId);

        var detail = await client.GetFromJsonAsync<PlaylistDetail>($"/api/playlists/{playlistId}");
        Assert.NotNull(detail);
        Assert.NotNull(detail!.DynamicConfig);
        Assert.Equal(10, detail.DynamicConfig!.MaxEpisodes);
        Assert.Equal([showId], detail.DynamicConfig.ShowIds);
    }

    // Same guard/pattern, covering the other two seed hooks added alongside seed-playlists
    // (#249): /dev/seed-subscriptions and /dev/seed-episode-states.
    [Fact]
    public async Task SeedSubscriptionAndEpisodeState_AreReturnedByApi()
    {
        var showId = $"test-show-{Guid.NewGuid():N}";
        var episodeId = $"{showId}-ep-0";

        using var client = fixture.CreateApiClient();
        var userId = $"test-user-{Guid.NewGuid():N}";

        await SeedShowAsync(client, showId);
        await SeedEpisodeAsync(client, showId, episodeId);

        var subscription = new Subscription(
            showId, userId, showId, ShowTitle: "Playlist Seed Test Show", ShowAuthor: "Test Author",
            ShowArtworkUrl: null, SubscribedAt: DateTimeOffset.UtcNow);
        var seedSubscriptionResponse = await client.PostAsJsonAsync(
            "/dev/seed-subscriptions", new List<Subscription> { subscription });
        Assert.Equal(HttpStatusCode.OK, seedSubscriptionResponse.StatusCode);

        var episodeState = new EpisodeState(
            episodeId, userId, episodeId, showId, PositionSeconds: 120, Completed: false,
            UpdatedAt: DateTimeOffset.UtcNow);
        var seedEpisodeStateResponse = await client.PostAsJsonAsync(
            "/dev/seed-episode-states", new List<EpisodeState> { episodeState });
        Assert.Equal(HttpStatusCode.OK, seedEpisodeStateResponse.StatusCode);

        await AuthenticateAsync(client, userId);

        var subscriptions = await client.GetFromJsonAsync<List<SubscriptionResponse>>("/api/subscriptions");
        Assert.Contains(subscriptions!, s => s.ShowId == showId);

        var stateResponse = await client.GetAsync($"/api/episodes/{episodeId}/state");
        Assert.Equal(HttpStatusCode.OK, stateResponse.StatusCode);
        var state = await stateResponse.Content.ReadFromJsonAsync<EpisodeStateResponse>();
        Assert.Equal(120, state?.PositionSeconds);
        Assert.False(state?.Completed);
    }

    private static async Task SeedShowAsync(HttpClient client, string showId)
    {
        var seedResponse = await client.PostAsJsonAsync("/dev/seed-show", new Show(
            showId,
            Title: "Playlist Seed Test Show",
            Author: "Test Author",
            FeedUrl: "https://example.com/feed.xml",
            ArtworkUrl: null,
            Description: "Seeded directly for integration testing.",
            Categories: ["Technology"]));
        Assert.Equal(HttpStatusCode.OK, seedResponse.StatusCode);
    }

    private static async Task SeedEpisodeAsync(HttpClient client, string showId, string episodeId)
    {
        var episode = new Episode(
            episodeId,
            showId,
            Title: "Episode 0",
            PublishedAt: DateTimeOffset.UtcNow,
            Duration: TimeSpan.FromMinutes(30),
            AudioUrl: $"https://example.com/{episodeId}.mp3",
            Description: null,
            BitrateKbps: null,
            FileSizeBytes: null);

        var seedResponse = await client.PostAsJsonAsync("/dev/seed-episodes", new List<Episode> { episode });
        Assert.Equal(HttpStatusCode.OK, seedResponse.StatusCode);
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

    private sealed record SubscriptionResponse(string Id, string UserId, string ShowId, string ShowTitle, string ShowAuthor, string? ShowArtworkUrl, DateTimeOffset SubscribedAt);

    private sealed record EpisodeStateResponse(string Id, string UserId, string EpisodeId, string ShowId, int PositionSeconds, bool Completed);
}
