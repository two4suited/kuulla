using System.Net;
using Kuulla.Api.Services;
using Microsoft.Extensions.Logging.Abstractions;

namespace Kuulla.Api.Tests;

public class PodcastFeedClientTests
{
    private const string FeedUrl = "https://feed.example/rss";
    private const string ChaptersUrl = "https://feed.example/ep1-chapters.json";

    private static PodcastFeedClient MakeSut(Func<Uri, HttpResponseMessage> route)
    {
        var httpClient = new HttpClient(TestHttpMessageHandler.Routed(route));
        return new PodcastFeedClient(httpClient, NullLogger<PodcastFeedClient>.Instance);
    }

    private static string FeedXml(string itemXml) => $"""
        <?xml version="1.0"?>
        <rss xmlns:podcast="https://podcastindex.org/namespace/1.0">
          <channel>
            <description>A show</description>
            {itemXml}
          </channel>
        </rss>
        """;

    [Fact]
    public async Task FetchAsync_PopulatesChaptersFromPodcastChaptersTag()
    {
        var itemXml = $"""
            <item>
              <title>Episode 1</title>
              <enclosure url="https://audio.example/1.mp3" length="100" />
              <podcast:chapters url="{ChaptersUrl}" type="application/json+chapters" />
            </item>
            """;
        var chaptersJson = """
            {
              "version": "1.2.0",
              "chapters": [
                { "startTime": 0, "title": "Intro" },
                { "startTime": 125.5, "title": "Sponsor", "img": "https://img.example/1.jpg", "url": "https://sponsor.example" }
              ]
            }
            """;
        var sut = MakeSut(uri => uri.AbsoluteUri == ChaptersUrl
            ? new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(chaptersJson) }
            : new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(FeedXml(itemXml)) });

        var feed = await sut.FetchAsync(FeedUrl, CancellationToken.None);

        var episode = Assert.Single(feed!.Episodes);
        Assert.NotNull(episode.Chapters);
        Assert.Equal(2, episode.Chapters!.Count);
        Assert.Equal(TimeSpan.Zero, episode.Chapters[0].StartTime);
        Assert.Equal("Intro", episode.Chapters[0].Title);
        Assert.Equal(TimeSpan.FromSeconds(125.5), episode.Chapters[1].StartTime);
        Assert.Equal("Sponsor", episode.Chapters[1].Title);
        Assert.Equal("https://img.example/1.jpg", episode.Chapters[1].ImageUrl);
        Assert.Equal("https://sponsor.example", episode.Chapters[1].Url);
    }

    [Fact]
    public async Task FetchAsync_PopulatesChaptersFromBareArrayShapedResponse()
    {
        var itemXml = $"""
            <item>
              <title>Episode 1</title>
              <enclosure url="https://audio.example/1.mp3" length="100" />
              <podcast:chapters url="{ChaptersUrl}" type="application/json+chapters" />
            </item>
            """;
        // Not every feed wraps the array in a { "chapters": [...] } document — some serve the
        // array itself as the JSON root.
        var chaptersJson = """
            [
              { "startTime": 0, "title": "Intro" },
              { "startTime": 60, "title": "Segment 1" }
            ]
            """;
        var sut = MakeSut(uri => uri.AbsoluteUri == ChaptersUrl
            ? new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(chaptersJson) }
            : new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(FeedXml(itemXml)) });

        var feed = await sut.FetchAsync(FeedUrl, CancellationToken.None);

        var episode = Assert.Single(feed!.Episodes);
        Assert.NotNull(episode.Chapters);
        Assert.Equal(2, episode.Chapters!.Count);
        Assert.Equal("Intro", episode.Chapters[0].Title);
        Assert.Equal(TimeSpan.FromSeconds(60), episode.Chapters[1].StartTime);
    }

    [Fact]
    public async Task FetchAsync_SkipsOnlyTheMalformedChapterEntry()
    {
        var itemXml = $"""
            <item>
              <title>Episode 1</title>
              <enclosure url="https://audio.example/1.mp3" length="100" />
              <podcast:chapters url="{ChaptersUrl}" type="application/json+chapters" />
            </item>
            """;
        var chaptersJson = """
            {
              "chapters": [
                { "startTime": 0, "title": "Intro" },
                { "title": "Missing start time" },
                { "startTime": 60, "title": "Segment 1" }
              ]
            }
            """;
        var sut = MakeSut(uri => uri.AbsoluteUri == ChaptersUrl
            ? new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(chaptersJson) }
            : new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(FeedXml(itemXml)) });

        var feed = await sut.FetchAsync(FeedUrl, CancellationToken.None);

        var episode = Assert.Single(feed!.Episodes);
        Assert.NotNull(episode.Chapters);
        Assert.Equal(2, episode.Chapters!.Count);
        Assert.Equal("Intro", episode.Chapters[0].Title);
        Assert.Equal("Segment 1", episode.Chapters[1].Title);
    }

    [Fact]
    public async Task FetchAsync_SkipsChapterEntryWithOutOfRangeStartTime()
    {
        var itemXml = $"""
            <item>
              <title>Episode 1</title>
              <enclosure url="https://audio.example/1.mp3" length="100" />
              <podcast:chapters url="{ChaptersUrl}" type="application/json+chapters" />
            </item>
            """;
        // A startTime this large overflows TimeSpan.FromSeconds — must be skipped as a per-entry
        // failure rather than throwing out of the whole chapters document.
        var chaptersJson = """
            {
              "chapters": [
                { "startTime": 0, "title": "Intro" },
                { "startTime": 1e20, "title": "Overflow" },
                { "startTime": 60, "title": "Segment 1" }
              ]
            }
            """;
        var sut = MakeSut(uri => uri.AbsoluteUri == ChaptersUrl
            ? new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(chaptersJson) }
            : new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(FeedXml(itemXml)) });

        var feed = await sut.FetchAsync(FeedUrl, CancellationToken.None);

        var episode = Assert.Single(feed!.Episodes);
        Assert.NotNull(episode.Chapters);
        Assert.Equal(2, episode.Chapters!.Count);
        Assert.Equal("Intro", episode.Chapters[0].Title);
        Assert.Equal("Segment 1", episode.Chapters[1].Title);
    }

    [Fact]
    public async Task FetchAsync_SkipsChapterEntryWithNegativeStartTime()
    {
        var itemXml = $"""
            <item>
              <title>Episode 1</title>
              <enclosure url="https://audio.example/1.mp3" length="100" />
              <podcast:chapters url="{ChaptersUrl}" type="application/json+chapters" />
            </item>
            """;
        var chaptersJson = """
            {
              "chapters": [
                { "startTime": 0, "title": "Intro" },
                { "startTime": -5, "title": "Negative" },
                { "startTime": 60, "title": "Segment 1" }
              ]
            }
            """;
        var sut = MakeSut(uri => uri.AbsoluteUri == ChaptersUrl
            ? new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(chaptersJson) }
            : new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(FeedXml(itemXml)) });

        var feed = await sut.FetchAsync(FeedUrl, CancellationToken.None);

        var episode = Assert.Single(feed!.Episodes);
        Assert.NotNull(episode.Chapters);
        Assert.Equal(2, episode.Chapters!.Count);
        Assert.Equal("Intro", episode.Chapters[0].Title);
        Assert.Equal("Segment 1", episode.Chapters[1].Title);
    }

    [Fact]
    public async Task FetchAsync_DoesNotFetchChaptersForItemWithNoEnclosure()
    {
        var itemXml = $"""
            <item>
              <title>Not really an episode</title>
              <podcast:chapters url="{ChaptersUrl}" type="application/json+chapters" />
            </item>
            """;
        var chaptersRequested = false;
        var sut = MakeSut(uri =>
        {
            if (uri.AbsoluteUri == ChaptersUrl)
            {
                chaptersRequested = true;
                return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("""{"chapters":[]}""") };
            }

            return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(FeedXml(itemXml)) };
        });

        var feed = await sut.FetchAsync(FeedUrl, CancellationToken.None);

        Assert.Empty(feed!.Episodes);
        Assert.False(chaptersRequested);
    }

    [Theory]
    [InlineData("http://localhost/chapters.json")]
    [InlineData("http://127.0.0.1/chapters.json")]
    [InlineData("http://169.254.169.254/chapters.json")] // cloud metadata endpoint
    [InlineData("http://10.0.0.5/chapters.json")]
    [InlineData("http://192.168.1.1/chapters.json")]
    [InlineData("ftp://feed.example/chapters.json")]
    [InlineData("not-a-url")]
    public async Task FetchAsync_DoesNotFetchChaptersFromUnsafeUrl(string unsafeChaptersUrl)
    {
        var itemXml = $"""
            <item>
              <title>Episode 1</title>
              <enclosure url="https://audio.example/1.mp3" length="100" />
              <podcast:chapters url="{unsafeChaptersUrl}" type="application/json+chapters" />
            </item>
            """;
        var chaptersRequested = false;
        var sut = MakeSut(uri =>
        {
            if (uri.AbsoluteUri == unsafeChaptersUrl)
            {
                chaptersRequested = true;
            }

            return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(FeedXml(itemXml)) };
        });

        var feed = await sut.FetchAsync(FeedUrl, CancellationToken.None);

        var episode = Assert.Single(feed!.Episodes);
        Assert.Null(episode.Chapters);
        Assert.False(chaptersRequested);
    }

    [Fact]
    public async Task FetchAsync_LeavesChaptersNullWhenTagAbsent()
    {
        var itemXml = """
            <item>
              <title>Episode 1</title>
              <enclosure url="https://audio.example/1.mp3" length="100" />
            </item>
            """;
        var sut = MakeSut(_ => new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(FeedXml(itemXml)) });

        var feed = await sut.FetchAsync(FeedUrl, CancellationToken.None);

        var episode = Assert.Single(feed!.Episodes);
        Assert.Null(episode.Chapters);
    }

    [Fact]
    public async Task FetchAsync_DoesNotFailWholeFeedWhenChaptersUrlFails()
    {
        var itemXml = $"""
            <item>
              <title>Episode 1</title>
              <enclosure url="https://audio.example/1.mp3" length="100" />
              <podcast:chapters url="{ChaptersUrl}" type="application/json+chapters" />
            </item>
            """;
        var sut = MakeSut(uri => uri.AbsoluteUri == ChaptersUrl
            ? new HttpResponseMessage(HttpStatusCode.NotFound)
            : new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(FeedXml(itemXml)) });

        var feed = await sut.FetchAsync(FeedUrl, CancellationToken.None);

        var episode = Assert.Single(feed!.Episodes);
        Assert.Equal("https://audio.example/1.mp3", episode.AudioUrl);
        Assert.Null(episode.Chapters);
    }
}
