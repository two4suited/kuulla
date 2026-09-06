using System.Net;
using System.Net.Http.Json;
using Kuulla.Core.Models;
using Xunit;

namespace Kuulla.AppHost.Tests;

[Collection(AppHostCollection.Name)]
public class SubscriptionFlowTests(AppHostFixture fixture)
{
    // End-to-end against the real API + Cosmos emulator (no mocks): mint a local test token,
    // seed a show through the API's own /dev/seed-show hook, then walk
    // subscribe -> list -> unsubscribe -> list through the actual Cosmos "subscriptions"
    // container.
    [Fact]
    public async Task Subscribe_List_Unsubscribe_RoundTripsThroughRealCosmos()
    {
        var showId = $"test-show-{Guid.NewGuid():N}";

        using var client = fixture.CreateApiClient();

        var seedResponse = await client.PostAsJsonAsync("/dev/seed-show", new Show(
            showId,
            Title: "Integration Test Show",
            Author: "Test Author",
            FeedUrl: "https://example.com/feed.xml",
            ArtworkUrl: null,
            Description: "Seeded directly for integration testing.",
            Categories: ["Technology"]));
        Assert.Equal(HttpStatusCode.OK, seedResponse.StatusCode);

        await AuthenticateAsync(client);

        var subscribeResponse = await client.PostAsJsonAsync("/api/subscriptions", new { ShowId = showId });
        Assert.Equal(HttpStatusCode.OK, subscribeResponse.StatusCode);
        var subscription = await subscribeResponse.Content.ReadFromJsonAsync<SubscriptionResponse>();
        Assert.Equal(showId, subscription?.ShowId);
        Assert.Equal("Integration Test Show", subscription?.ShowTitle);

        var listAfterSubscribe = await client.GetFromJsonAsync<List<SubscriptionResponse>>("/api/subscriptions");
        Assert.Contains(listAfterSubscribe!, s => s.ShowId == showId);

        var unsubscribeResponse = await client.DeleteAsync($"/api/subscriptions/{showId}");
        Assert.Equal(HttpStatusCode.NoContent, unsubscribeResponse.StatusCode);

        var listAfterUnsubscribe = await client.GetFromJsonAsync<List<SubscriptionResponse>>("/api/subscriptions");
        Assert.DoesNotContain(listAfterUnsubscribe!, s => s.ShowId == showId);
    }

    [Fact]
    public async Task Subscribe_UnknownShow_ReturnsNotFound()
    {
        using var client = fixture.CreateApiClient();

        await AuthenticateAsync(client);

        var subscribeResponse = await client.PostAsJsonAsync(
            "/api/subscriptions", new { ShowId = $"missing-show-{Guid.NewGuid():N}" });

        Assert.Equal(HttpStatusCode.NotFound, subscribeResponse.StatusCode);
    }

    // Mints a local test token via /dev/test-token and attaches it to the client so subsequent
    // requests hit authenticated endpoints.
    private static async Task AuthenticateAsync(HttpClient client)
    {
        var tokenResponse = await client.PostAsync("/dev/test-token", content: null);
        Assert.Equal(HttpStatusCode.OK, tokenResponse.StatusCode);
        var tokenPayload = await tokenResponse.Content.ReadFromJsonAsync<TestTokenResponse>();
        Assert.False(string.IsNullOrEmpty(tokenPayload?.Token));

        client.DefaultRequestHeaders.Authorization = new("Bearer", tokenPayload!.Token);
    }

    private sealed record TestTokenResponse(string Token);

    private sealed record SubscriptionResponse(string Id, string UserId, string ShowId, string ShowTitle, string ShowAuthor, string? ShowArtworkUrl, DateTimeOffset SubscribedAt);
}
