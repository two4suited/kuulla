using System.Net;
using System.Net.Http.Json;
using System.Text;
using Kuulla.Core.Models;
using Kuulla.Core.Services;
using Xunit;

namespace Kuulla.AppHost.Tests;

[Collection(AppHostCollection.Name)]
public class OpmlImportFlowTests(AppHostFixture fixture)
{
    // End-to-end against the real API + Cosmos emulator: a user already subscribed to feed A
    // imports an OPML with A (given as http + trailing slash), a new feed B, and a dead URL.
    // A is skipped (not re-subscribed, no duplicate), B is added, the dead URL is reported.
    [Fact]
    public async Task Import_SkipsAlreadySubscribed_AddsNew_ReportsDead_AndRoundTripsThroughRealCosmos()
    {
        var userId = $"test-user-{Guid.NewGuid():N}";
        var feedA = $"https://a-{Guid.NewGuid():N}.example/feed";
        var feedB = $"https://b-{Guid.NewGuid():N}.example/feed";
        var deadFeed = $"https://{Guid.NewGuid():N}.invalid/feed";

        using var client = fixture.CreateApiClient();

        // Already subscribed to A. The snapshot carries FeedUrl, so import dedups without a show read.
        var existingSubscription = new Subscription(
            Guid.NewGuid().ToString("N"), userId, ShowId: $"show-a-{Guid.NewGuid():N}",
            ShowTitle: "Feed A", ShowAuthor: "A", ShowArtworkUrl: null,
            SubscribedAt: DateTimeOffset.UtcNow, LatestEpisodePublishedAt: null, FeedUrl: feedA);
        var seedSubResponse = await client.PostAsJsonAsync(
            "/dev/seed-subscriptions", new List<Subscription> { existingSubscription });
        Assert.Equal(HttpStatusCode.OK, seedSubResponse.StatusCode);

        // Pre-seed B as the feed-sourced show import would create, so the "added" path needs no
        // network. Id/description mirror ShowService.GetOrCreateByFeedUrlAsync + a populated feed.
        var showB = new Show(
            ShowService.FeedShowId(FeedUrl.Normalize(feedB)),
            Title: "Feed B", Author: "B", FeedUrl: feedB, ArtworkUrl: null,
            Description: "Seeded so import resolves B without fetching a live feed.",
            Categories: []);
        var seedShowResponse = await client.PostAsJsonAsync("/dev/seed-show", showB);
        Assert.Equal(HttpStatusCode.OK, seedShowResponse.StatusCode);

        await AuthenticateAsync(client, userId);

        var opml = $"""
            <?xml version="1.0" encoding="UTF-8"?>
            <opml version="2.0">
              <head><title>Subscriptions</title></head>
              <body>
                <outline type="rss" text="Feed A" xmlUrl="{feedA.Replace("https://", "http://")}/" />
                <outline type="rss" text="Feed B" xmlUrl="{feedB}" />
                <outline type="rss" text="Dead" xmlUrl="{deadFeed}" />
              </body>
            </opml>
            """;

        using var form = new MultipartFormDataContent();
        var fileContent = new ByteArrayContent(Encoding.UTF8.GetBytes(opml));
        fileContent.Headers.ContentType = new("text/x-opml");
        form.Add(fileContent, "file", "subscriptions.opml");

        var importResponse = await client.PostAsync("/api/subscriptions/import", form);
        Assert.Equal(HttpStatusCode.OK, importResponse.StatusCode);

        var result = await importResponse.Content.ReadFromJsonAsync<ImportResponse>();
        Assert.NotNull(result);
        Assert.Equal(1, result!.Added);
        Assert.Equal(1, result.AlreadySubscribed);
        var failure = Assert.Single(result.Failed);
        Assert.Equal(FeedUrl.Normalize(deadFeed), failure.FeedUrl);

        // B is now subscribed; A is still there exactly once.
        var subscriptions = await client.GetFromJsonAsync<List<SubscriptionResponse>>("/api/subscriptions");
        Assert.Single(subscriptions!, s => s.ShowId == existingSubscription.ShowId);
        Assert.Contains(subscriptions!, s => s.ShowId == showB.Id);
    }

    [Fact]
    public async Task Import_WithNoFile_Returns400()
    {
        using var client = fixture.CreateApiClient();
        await AuthenticateAsync(client, $"test-user-{Guid.NewGuid():N}");

        using var form = new MultipartFormDataContent();
        var response = await client.PostAsync("/api/subscriptions/import", form);

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
    }

    [Fact]
    public async Task Import_WithMalformedOpml_Returns400()
    {
        using var client = fixture.CreateApiClient();
        await AuthenticateAsync(client, $"test-user-{Guid.NewGuid():N}");

        using var form = new MultipartFormDataContent();
        form.Add(new ByteArrayContent(Encoding.UTF8.GetBytes("<opml><body><outline ")), "file", "bad.opml");

        var response = await client.PostAsync("/api/subscriptions/import", form);

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
    }

    private static async Task AuthenticateAsync(HttpClient client, string userId)
    {
        var tokenResponse = await client.PostAsync($"/dev/test-token?sub={userId}", content: null);
        Assert.Equal(HttpStatusCode.OK, tokenResponse.StatusCode);
        var tokenPayload = await tokenResponse.Content.ReadFromJsonAsync<TestTokenResponse>();
        client.DefaultRequestHeaders.Authorization = new("Bearer", tokenPayload!.Token);
    }

    private sealed record TestTokenResponse(string Token);

    private sealed record ImportResponse(int Added, int AlreadySubscribed, List<ImportFailure> Failed);

    private sealed record ImportFailure(string FeedUrl, string Reason);

    private sealed record SubscriptionResponse(string Id, string UserId, string ShowId, string ShowTitle);
}
