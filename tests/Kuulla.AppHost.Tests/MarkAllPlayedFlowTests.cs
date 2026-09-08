using System.Net;
using System.Net.Http.Json;
using Kuulla.Core.Models;
using Xunit;

namespace Kuulla.AppHost.Tests;

[Collection(AppHostCollection.Name)]
public class MarkAllPlayedFlowTests(AppHostFixture fixture)
{
    // End-to-end against the real API + Cosmos emulator: "Mark all played" on the Show screen
    // (#490). A user subscribed to a show with cached episodes and mixed existing state should,
    // in one request, end up with every episode marked user-played — and a re-run should be a
    // no-op.
    [Fact]
    public async Task MarkAllPlayed_MarksEveryEpisodePlayed_AndIsIdempotent()
    {
        var showId = $"test-show-{Guid.NewGuid():N}";
        using var client = fixture.CreateApiClient();

        await SeedShowAsync(client, showId);
        var episodeIds = await SeedEpisodesAsync(client, showId, count: 3);

        await AuthenticateAsync(client);
        await SubscribeAsync(client, showId);

        // Leave one episode part-listened before the bulk mark — it should end up completed too.
        var inProgress = await client.PutAsJsonAsync(
            $"/api/episodes/{episodeIds[1]}/state",
            new { ShowId = showId, PositionSeconds = 30, Completed = false, DeviceId = "device-a" });
        Assert.Equal(HttpStatusCode.OK, inProgress.StatusCode);

        var response = await client.PostAsJsonAsync(
            $"/api/shows/{showId}/episode-state/mark-all-played", new { DeviceId = "device-a" });
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);

        var result = await response.Content.ReadFromJsonAsync<MarkAllPlayedResult>();
        Assert.NotNull(result);
        Assert.Equal(3, result!.TotalEpisodes);
        Assert.Equal(3, result.UpdatedCount);

        foreach (var episodeId in episodeIds)
        {
            var state = await client.GetFromJsonAsync<EpisodeStateResponse>($"/api/episodes/{episodeId}/state");
            Assert.NotNull(state);
            Assert.True(state!.Completed);
            Assert.False(state.AutoPlayed);
        }

        // Idempotent: nothing left to write on the second call.
        var rerun = await client.PostAsJsonAsync(
            $"/api/shows/{showId}/episode-state/mark-all-played", new { DeviceId = "device-a" });
        Assert.Equal(HttpStatusCode.OK, rerun.StatusCode);
        var rerunResult = await rerun.Content.ReadFromJsonAsync<MarkAllPlayedResult>();
        Assert.NotNull(rerunResult);
        Assert.Equal(0, rerunResult!.UpdatedCount);
    }

    [Fact]
    public async Task MarkAllPlayed_ReturnsNotFound_ForUnknownShow()
    {
        using var client = fixture.CreateApiClient();
        await AuthenticateAsync(client);

        var response = await client.PostAsJsonAsync(
            $"/api/shows/does-not-exist-{Guid.NewGuid():N}/episode-state/mark-all-played", new { DeviceId = "device-a" });

        Assert.Equal(HttpStatusCode.NotFound, response.StatusCode);
    }

    private static async Task SeedShowAsync(HttpClient client, string showId)
    {
        var seedResponse = await client.PostAsJsonAsync("/dev/seed-show", new Show(
            showId,
            Title: "Mark All Played Test Show",
            Author: "Test Author",
            FeedUrl: "https://example.com/feed.xml",
            ArtworkUrl: null,
            Description: "Seeded directly for integration testing.",
            Categories: ["Technology"]));
        Assert.Equal(HttpStatusCode.OK, seedResponse.StatusCode);
    }

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

    private static async Task AuthenticateAsync(HttpClient client)
    {
        var tokenResponse = await client.PostAsync($"/dev/test-token?sub=test-user-{Guid.NewGuid():N}", content: null);
        Assert.Equal(HttpStatusCode.OK, tokenResponse.StatusCode);
        var tokenPayload = await tokenResponse.Content.ReadFromJsonAsync<TestTokenResponse>();
        Assert.False(string.IsNullOrEmpty(tokenPayload?.Token));

        client.DefaultRequestHeaders.Authorization = new("Bearer", tokenPayload!.Token);
    }

    private sealed record TestTokenResponse(string Token);

    private sealed record EpisodeStateResponse(
        string Id, string UserId, string EpisodeId, string ShowId, int PositionSeconds, bool Completed, bool AutoPlayed);
}
