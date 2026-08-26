using System.Net;
using System.Net.Http.Json;
using Kuulla.Api.Services;

namespace Kuulla.Api.Tests;

public class ItunesPodcastDirectoryClientTests
{
    [Fact]
    public async Task GetTrendingAsync_ReturnsShowsInChartOrderWithFeedUrlsFromLookup()
    {
        var chartsJson = """
        {
          "feed": {
            "entry": [
              { "id": { "attributes": { "im:id": "111" } } },
              { "id": { "attributes": { "im:id": "222" } } }
            ]
          }
        }
        """;
        var lookupJson = """
        {
          "results": [
            { "collectionId": 222, "collectionName": "Second", "artistName": "Two", "feedUrl": "https://feeds.example/2", "artworkUrl600": "https://art/2.jpg", "genres": ["Comedy"] },
            { "collectionId": 111, "collectionName": "First", "artistName": "One", "feedUrl": "https://feeds.example/1", "artworkUrl600": "https://art/1.jpg", "genres": ["News"] }
          ]
        }
        """;

        var handler = TestHttpMessageHandler.Routed(uri => new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new StringContent(uri.AbsolutePath.Contains("toppodcasts") ? chartsJson : lookupJson, System.Text.Encoding.UTF8, "application/json"),
        });
        var httpClient = new HttpClient(handler) { BaseAddress = new Uri("https://itunes.apple.com/") };
        var sut = new ItunesPodcastDirectoryClient(httpClient);

        var results = await sut.GetTrendingAsync(null, CancellationToken.None);

        Assert.Equal(["111", "222"], results.Select(s => s.Id));
        Assert.Equal("First", results[0].Title);
        Assert.Equal("https://feeds.example/1", results[0].FeedUrl);
    }

    [Fact]
    public async Task GetTrendingAsync_UsesGenreInChartsUrlWhenCategoryProvided()
    {
        Uri? requestedChartsUri = null;
        var handler = TestHttpMessageHandler.Routed(uri =>
        {
            if (uri.AbsolutePath.Contains("toppodcasts"))
            {
                requestedChartsUri = uri;
                return new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(new { feed = new { } }) };
            }

            return new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(new { results = Array.Empty<object>() }) };
        });
        var httpClient = new HttpClient(handler) { BaseAddress = new Uri("https://itunes.apple.com/") };
        var sut = new ItunesPodcastDirectoryClient(httpClient);

        var results = await sut.GetTrendingAsync("1489", CancellationToken.None);

        Assert.Empty(results);
        Assert.Contains("genre=1489", requestedChartsUri!.PathAndQuery);
    }

    [Fact]
    public async Task GetTrendingAsync_DropsChartEntriesMissingFromLookup()
    {
        var chartsJson = """
        {
          "feed": {
            "entry": [
              { "id": { "attributes": { "im:id": "111" } } },
              { "id": { "attributes": { "im:id": "222" } } }
            ]
          }
        }
        """;
        var lookupJson = """
        {
          "results": [
            { "collectionId": 111, "collectionName": "First", "artistName": "One", "feedUrl": "https://feeds.example/1" }
          ]
        }
        """;
        var handler = TestHttpMessageHandler.Routed(uri => new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new StringContent(uri.AbsolutePath.Contains("toppodcasts") ? chartsJson : lookupJson, System.Text.Encoding.UTF8, "application/json"),
        });
        var httpClient = new HttpClient(handler) { BaseAddress = new Uri("https://itunes.apple.com/") };
        var sut = new ItunesPodcastDirectoryClient(httpClient);

        var results = await sut.GetTrendingAsync(null, CancellationToken.None);

        Assert.Single(results);
        Assert.Equal("111", results[0].Id);
    }

    [Fact]
    public async Task GetTrendingAsync_HandlesSingleEntrySerializedAsBareObject()
    {
        // Apple's feed serializes "entry" as a bare object, not a one-element array,
        // when the chart has exactly one result.
        var chartsJson = """
        {
          "feed": {
            "entry": { "id": { "attributes": { "im:id": "111" } } }
          }
        }
        """;
        var lookupJson = """
        {
          "results": [
            { "collectionId": 111, "collectionName": "First", "artistName": "One", "feedUrl": "https://feeds.example/1" }
          ]
        }
        """;
        var handler = TestHttpMessageHandler.Routed(uri => new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new StringContent(uri.AbsolutePath.Contains("toppodcasts") ? chartsJson : lookupJson, System.Text.Encoding.UTF8, "application/json"),
        });
        var httpClient = new HttpClient(handler) { BaseAddress = new Uri("https://itunes.apple.com/") };
        var sut = new ItunesPodcastDirectoryClient(httpClient);

        var results = await sut.GetTrendingAsync("some-narrow-genre", CancellationToken.None);

        Assert.Single(results);
        Assert.Equal("111", results[0].Id);
    }

    [Fact]
    public async Task GetTrendingAsync_ReturnsEmptyWhenChartsFeedHasNoEntries()
    {
        var handler = TestHttpMessageHandler.Json(new { feed = new { } });
        var httpClient = new HttpClient(handler) { BaseAddress = new Uri("https://itunes.apple.com/") };
        var sut = new ItunesPodcastDirectoryClient(httpClient);

        var results = await sut.GetTrendingAsync(null, CancellationToken.None);

        Assert.Empty(results);
    }
}
