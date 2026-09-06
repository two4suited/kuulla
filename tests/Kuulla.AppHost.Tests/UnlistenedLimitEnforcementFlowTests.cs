using System.Net;
using System.Net.Http.Json;
using Kuulla.Core.Models;
using Xunit;

namespace Kuulla.AppHost.Tests;

[Collection(AppHostCollection.Name)]
public class UnlistenedLimitEnforcementFlowTests(AppHostFixture fixture)
{
    // End-to-end against the real API + Cosmos emulator (no mocks): a user subscribed to a show
    // with five already-cached episodes and no existing episode state. Lowering the unlistened
    // limit — globally, or as a per-show override — should retroactively auto-mark the older
    // episodes played rather than waiting for the show's next feed refresh (#135).
    [Fact]
    public async Task UpdateGlobalLimit_AutoMarksOlderEpisodesPlayed()
    {
        var showId = $"test-show-{Guid.NewGuid():N}";
        using var client = fixture.CreateApiClient();

        await SeedShowAsync(client, showId);
        var episodeIds = await SeedEpisodesAsync(client, showId, count: 5);

        await AuthenticateAsync(client);
        await SubscribeAsync(client, showId);

        var updateResponse = await client.PutAsJsonAsync("/api/settings", new { UnlistenedEpisodeCount = 2 });
        Assert.Equal(HttpStatusCode.OK, updateResponse.StatusCode);

        // episodeIds is newest-first (matches PublishedAt DESC) — the newest 2 should stay
        // unplayed, the rest should be auto-marked.
        await AssertPlayedAsync(client, episodeIds[0], expectedAutoPlayed: false);
        await AssertPlayedAsync(client, episodeIds[1], expectedAutoPlayed: false);
        await AssertPlayedAsync(client, episodeIds[2], expectedAutoPlayed: true);
        await AssertPlayedAsync(client, episodeIds[3], expectedAutoPlayed: true);
        await AssertPlayedAsync(client, episodeIds[4], expectedAutoPlayed: true);
    }

    [Fact]
    public async Task UpdateShowLimit_AutoMarksOlderEpisodesPlayed_WithoutOverwritingExistingState()
    {
        var showId = $"test-show-{Guid.NewGuid():N}";
        using var client = fixture.CreateApiClient();

        await SeedShowAsync(client, showId);
        var episodeIds = await SeedEpisodesAsync(client, showId, count: 3);

        await AuthenticateAsync(client);
        await SubscribeAsync(client, showId);

        // Manually mark the oldest episode played before enforcement runs — the manual state
        // must survive enforcement untouched (not flipped to AutoPlayed).
        var manualStateResponse = await client.PutAsJsonAsync(
            $"/api/episodes/{episodeIds[2]}/state",
            new { ShowId = showId, PositionSeconds = 42, Completed = true, DeviceId = "manual-device" });
        Assert.Equal(HttpStatusCode.OK, manualStateResponse.StatusCode);

        var updateResponse = await client.PutAsJsonAsync($"/api/settings/shows/{showId}", new { UnlistenedEpisodeCount = 1 });
        Assert.Equal(HttpStatusCode.OK, updateResponse.StatusCode);

        await AssertPlayedAsync(client, episodeIds[0], expectedAutoPlayed: false);
        await AssertPlayedAsync(client, episodeIds[1], expectedAutoPlayed: true);

        var manualState = await client.GetFromJsonAsync<EpisodeStateResponse>($"/api/episodes/{episodeIds[2]}/state");
        Assert.NotNull(manualState);
        Assert.False(manualState!.AutoPlayed);
        Assert.Equal(42, manualState.PositionSeconds);
    }

    private static async Task SeedShowAsync(HttpClient client, string showId)
    {
        var seedResponse = await client.PostAsJsonAsync("/dev/seed-show", new Show(
            showId,
            Title: "Enforcement Test Show",
            Author: "Test Author",
            FeedUrl: "https://example.com/feed.xml",
            ArtworkUrl: null,
            Description: "Seeded directly for integration testing.",
            Categories: ["Technology"]));
        Assert.Equal(HttpStatusCode.OK, seedResponse.StatusCode);
    }

    // Seeds `count` episodes with descending PublishedAt (newest first) and returns their ids
    // in that same newest-first order, matching the API's episode ordering.
    private static async Task<IReadOnlyList<string>> SeedEpisodesAsync(HttpClient client, string showId, int count)
    {
        var baseTime = DateTimeOffset.UtcNow;
        var episodeIds = new List<string>();
        var episodes = new List<Episode>();
        for (var i = 0; i < count; i++)
        {
            var episodeId = $"{showId}-ep-{i}";
            episodeIds.Add(episodeId);
            episodes.Add(new Episode(
                episodeId,
                showId,
                Title: $"Episode {i}",
                PublishedAt: baseTime.AddDays(-i),
                Duration: TimeSpan.FromMinutes(30),
                AudioUrl: $"https://example.com/{episodeId}.mp3",
                Description: null,
                BitrateKbps: null,
                FileSizeBytes: null));
        }

        var seedResponse = await client.PostAsJsonAsync("/dev/seed-episodes", episodes);
        Assert.Equal(HttpStatusCode.OK, seedResponse.StatusCode);

        return episodeIds;
    }

    private static async Task SubscribeAsync(HttpClient client, string showId)
    {
        var subscribeResponse = await client.PostAsJsonAsync("/api/subscriptions", new { ShowId = showId });
        Assert.Equal(HttpStatusCode.OK, subscribeResponse.StatusCode);
    }

    private static async Task AssertPlayedAsync(HttpClient client, string episodeId, bool expectedAutoPlayed)
    {
        var response = await client.GetAsync($"/api/episodes/{episodeId}/state");
        if (!expectedAutoPlayed)
        {
            Assert.Equal(HttpStatusCode.NotFound, response.StatusCode);
            return;
        }

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        var state = await response.Content.ReadFromJsonAsync<EpisodeStateResponse>();
        Assert.NotNull(state);
        Assert.True(state!.AutoPlayed);
        Assert.True(state.Completed);
    }

    // Mints a local test token for a fresh, unique user via /dev/test-token and attaches it to
    // the client. Unlike the other AppHost.Tests classes, these tests mutate global (user-level)
    // settings — sharing "local-test-user" with them would make GetThenUpdate_RoundTripsThroughRealCosmos's
    // "brand new user gets defaults" assumption order-dependent, so each test here gets its own
    // isolated user instead.
    private static async Task AuthenticateAsync(HttpClient client)
    {
        var tokenResponse = await client.PostAsync($"/dev/test-token?sub=test-user-{Guid.NewGuid():N}", content: null);
        Assert.Equal(HttpStatusCode.OK, tokenResponse.StatusCode);
        var tokenPayload = await tokenResponse.Content.ReadFromJsonAsync<TestTokenResponse>();
        Assert.False(string.IsNullOrEmpty(tokenPayload?.Token));

        client.DefaultRequestHeaders.Authorization = new("Bearer", tokenPayload!.Token);
    }

    private sealed record TestTokenResponse(string Token);

    private sealed record EpisodeStateResponse(string Id, string UserId, string EpisodeId, string ShowId, int PositionSeconds, bool Completed, bool AutoPlayed);
}
