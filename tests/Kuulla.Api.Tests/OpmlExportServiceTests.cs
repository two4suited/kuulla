using System.Xml.Linq;
using Kuulla.Api.Services;
using Kuulla.Core.Models;
using Kuulla.Core.Services;
using Moq;

namespace Kuulla.Api.Tests;

public class OpmlExportServiceTests
{
    private const string UserId = "user-1";

    private readonly Mock<ISubscriptionService> _subscriptions = new();
    private readonly Mock<IShowService> _shows = new();
    private readonly OpmlExportService _sut;

    public OpmlExportServiceTests()
    {
        _sut = new OpmlExportService(_subscriptions.Object, _shows.Object);
    }

    private void HasSubscriptions(params Subscription[] subscriptions) =>
        _subscriptions.Setup(s => s.GetSubscriptionsAsync(UserId, It.IsAny<CancellationToken>()))
            .ReturnsAsync(subscriptions);

    private static Subscription Sub(string title, string? feedUrl, string showId = "show") =>
        new(showId, UserId, showId, title, "Author", null, DateTimeOffset.UtcNow, null, feedUrl);

    [Fact]
    public async Task ExportAsync_RoundTripsThroughOpmlParserToTheSameFeedUrls()
    {
        HasSubscriptions(
            Sub("Show B", "https://b.example/feed", "b"),
            Sub("Show A", "https://a.example/feed", "a"),
            Sub("Show C", "https://c.example/feed", "c"));

        var opml = await _sut.ExportAsync(UserId, CancellationToken.None);
        var parsed = OpmlParser.Parse(opml);

        Assert.Equal(
            new[] { "https://a.example/feed", "https://b.example/feed", "https://c.example/feed" },
            parsed.Select(f => f.FeedUrl));
    }

    [Fact]
    public async Task ExportAsync_OrdersOutlinesByTitleCaseInsensitively()
    {
        HasSubscriptions(
            Sub("zebra", "https://z.example/feed", "z"),
            Sub("Apple", "https://a.example/feed", "a"),
            Sub("mango", "https://m.example/feed", "m"));

        var opml = await _sut.ExportAsync(UserId, CancellationToken.None);
        var titles = XDocument.Parse(opml).Descendants("outline").Select(o => (string)o.Attribute("title")!);

        Assert.Equal(new[] { "Apple", "mango", "zebra" }, titles);
    }

    [Fact]
    public async Task ExportAsync_ResolvesLegacySubscriptionsWithoutASnapshotFeedUrlByReadingTheShow()
    {
        HasSubscriptions(Sub("Legacy", feedUrl: null, showId: "legacy-show"));
        _shows.Setup(s => s.TryGetFeedUrlAsync("legacy-show", It.IsAny<CancellationToken>()))
            .ReturnsAsync("https://legacy.example/feed");

        var parsed = OpmlParser.Parse(await _sut.ExportAsync(UserId, CancellationToken.None));

        Assert.Equal("https://legacy.example/feed", Assert.Single(parsed).FeedUrl);
    }

    [Fact]
    public async Task ExportAsync_OmitsSubscriptionsWhoseFeedUrlCannotBeResolved()
    {
        HasSubscriptions(
            Sub("Has feed", "https://a.example/feed", "a"),
            Sub("No feed", feedUrl: null, showId: "gone"));
        _shows.Setup(s => s.TryGetFeedUrlAsync("gone", It.IsAny<CancellationToken>()))
            .ReturnsAsync((string?)null);

        var parsed = OpmlParser.Parse(await _sut.ExportAsync(UserId, CancellationToken.None));

        Assert.Equal("https://a.example/feed", Assert.Single(parsed).FeedUrl);
    }

    [Fact]
    public async Task ExportAsync_WritesAnOpml2HeadWithTitleAndDateCreated()
    {
        HasSubscriptions(Sub("Show", "https://a.example/feed", "a"));

        var document = XDocument.Parse(await _sut.ExportAsync(UserId, CancellationToken.None));

        Assert.Equal("2.0", (string)document.Root!.Attribute("version")!);
        var head = document.Root.Element("head")!;
        Assert.Equal("Kuulla subscriptions", (string)head.Element("title")!);
        Assert.True(DateTimeOffset.TryParse((string)head.Element("dateCreated")!, out _));
    }

    [Fact]
    public async Task ExportAsync_EscapesSpecialCharactersInTitlesAndUrls()
    {
        HasSubscriptions(Sub("Ampersands & \"quotes\" <tags>", "https://a.example/feed?a=1&b=2", "a"));

        var opml = await _sut.ExportAsync(UserId, CancellationToken.None);
        var outline = XDocument.Parse(opml).Descendants("outline").Single();

        Assert.Equal("Ampersands & \"quotes\" <tags>", (string)outline.Attribute("title")!);
        Assert.Equal("https://a.example/feed?a=1&b=2", (string)outline.Attribute("xmlUrl")!);
    }

    [Fact]
    public async Task ExportAsync_NoSubscriptions_StillProducesAWellFormedEmptyOpml()
    {
        HasSubscriptions();

        var parsed = OpmlParser.Parse(await _sut.ExportAsync(UserId, CancellationToken.None));

        Assert.Empty(parsed);
    }
}
