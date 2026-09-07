using System.Net;
using System.Net.Http.Json;
using System.Text;
using Kuulla.Api.Services;
using Kuulla.Core.Models;
using Kuulla.Core.Services;
using Xunit;

namespace Kuulla.AppHost.Tests;

[Collection(AppHostCollection.Name)]
public class OpmlExportFlowTests(AppHostFixture fixture)
{
    [Fact]
    public async Task Export_ReturnsAnOpmlAttachment_ThatRoundTripsBackThroughImport()
    {
        var exporter = $"test-user-{Guid.NewGuid():N}";
        var importer = $"test-user-{Guid.NewGuid():N}";
        var feed1 = $"https://one-{Guid.NewGuid():N}.example/feed";
        var feed2 = $"https://two-{Guid.NewGuid():N}.example/feed";

        using var client = fixture.CreateApiClient();

        // The exporter is subscribed to two shows (feed URL snapshotted on the subscription).
        var subs = new[] { (feed1, "Show One"), (feed2, "Show Two") }
            .Select(x => new Subscription(
                Guid.NewGuid().ToString("N"), exporter, ShowId: ShowService.FeedShowId(FeedUrl.Normalize(x.Item1)),
                ShowTitle: x.Item2, ShowAuthor: "Author", ShowArtworkUrl: null,
                SubscribedAt: DateTimeOffset.UtcNow, LatestEpisodePublishedAt: null, FeedUrl: x.Item1))
            .ToList();
        var seedSubs = await client.PostAsJsonAsync("/dev/seed-subscriptions", subs);
        Assert.Equal(HttpStatusCode.OK, seedSubs.StatusCode);

        // Pre-seed both shows so the importer's added-path needs no live feed fetch.
        foreach (var sub in subs)
        {
            var seedShow = await client.PostAsJsonAsync("/dev/seed-show", new Show(
                sub.ShowId, sub.ShowTitle, "Author", sub.FeedUrl!, null,
                Description: "Seeded so import resolves it offline.", Categories: []));
            Assert.Equal(HttpStatusCode.OK, seedShow.StatusCode);
        }

        await AuthenticateAsync(client, exporter);
        var exportResponse = await client.GetAsync("/api/subscriptions/export");

        Assert.Equal(HttpStatusCode.OK, exportResponse.StatusCode);
        Assert.Equal("text/x-opml", exportResponse.Content.Headers.ContentType?.MediaType);
        Assert.Equal("kuulla-subscriptions.opml", exportResponse.Content.Headers.ContentDisposition?.FileNameStar
            ?? exportResponse.Content.Headers.ContentDisposition?.FileName?.Trim('"'));

        var opml = await exportResponse.Content.ReadAsStringAsync();
        var parsed = OpmlParser.Parse(opml);
        Assert.Equal(
            new[] { FeedUrl.Normalize(feed1), FeedUrl.Normalize(feed2) }.OrderBy(u => u),
            parsed.Select(f => f.FeedUrl).OrderBy(u => u));

        // Feed the exact bytes back into import as a different user — both feeds should be added.
        using var form = new MultipartFormDataContent();
        var file = new ByteArrayContent(Encoding.UTF8.GetBytes(opml));
        file.Headers.ContentType = new("text/x-opml");
        form.Add(file, "file", "kuulla-subscriptions.opml");

        await AuthenticateAsync(client, importer);
        var importResponse = await client.PostAsync("/api/subscriptions/import", form);
        Assert.Equal(HttpStatusCode.OK, importResponse.StatusCode);

        var result = await importResponse.Content.ReadFromJsonAsync<ImportResponse>();
        Assert.Equal(2, result!.Added);
        Assert.Empty(result.Failed);
    }

    [Fact]
    public async Task Export_WithNoSubscriptions_ReturnsAWellFormedEmptyOpml()
    {
        using var client = fixture.CreateApiClient();
        await AuthenticateAsync(client, $"test-user-{Guid.NewGuid():N}");

        var response = await client.GetAsync("/api/subscriptions/export");

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        var parsed = OpmlParser.Parse(await response.Content.ReadAsStringAsync());
        Assert.Empty(parsed);
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
}
