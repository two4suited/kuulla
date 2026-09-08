using Kuulla.Api.Services;
using Kuulla.Core.Models;
using Kuulla.Core.Services;
using Moq;

namespace Kuulla.Api.Tests;

public class OpmlImportServiceTests
{
    private const string UserId = "user-1";

    private readonly Mock<ISubscriptionService> _subscriptions = new();
    private readonly Mock<IShowService> _shows = new();
    private readonly OpmlImportService _sut;

    public OpmlImportServiceTests()
    {
        _sut = new OpmlImportService(_subscriptions.Object, _shows.Object);
        _subscriptions.Setup(s => s.GetSubscriptionsAsync(UserId, It.IsAny<CancellationToken>()))
            .ReturnsAsync(Array.Empty<Subscription>());
    }

    private static string Opml(params string[] feedUrls) => $"""
        <opml version="2.0"><body>
        {string.Join('\n', feedUrls.Select(u => $"<outline type=\"rss\" xmlUrl=\"{u}\" />"))}
        </body></opml>
        """;

    private static Show ShowWithFeed(string id, string feedUrl) =>
        new(id, id, id, feedUrl, null, null, []);

    private static Subscription Sub(string showId, string? feedUrl) =>
        new(showId, UserId, showId, showId, showId, null, DateTimeOffset.UtcNow, null, feedUrl);

    [Fact]
    public async Task ImportAsync_SkipsAlreadySubscribedFeeds_AddsNewOnes_AndReportsDeadFeeds()
    {
        _subscriptions.Setup(s => s.GetSubscriptionsAsync(UserId, It.IsAny<CancellationToken>()))
            .ReturnsAsync(new[] { Sub("show-a", "https://a.example/feed") });

        _shows.Setup(s => s.GetOrCreateByFeedUrlAsync("https://b.example/feed", It.IsAny<CancellationToken>()))
            .ReturnsAsync(ShowWithFeed("show-b", "https://b.example/feed"));
        _subscriptions.Setup(s => s.SubscribeAsync(UserId, "show-b", It.IsAny<CancellationToken>()))
            .ReturnsAsync(Sub("show-b", "https://b.example/feed"));

        _shows.Setup(s => s.GetOrCreateByFeedUrlAsync("https://c.example/feed", It.IsAny<CancellationToken>()))
            .ReturnsAsync((Show?)null);

        // Feed A is given http + trailing slash in the file — it must still match the subscribed
        // "https://a.example/feed" after normalization.
        var result = await _sut.ImportAsync(
            UserId,
            Opml("http://a.example/feed/", "https://b.example/feed", "https://c.example/feed"),
            CancellationToken.None);

        Assert.Equal(1, result.Added);
        Assert.Equal(new[] { "show-b" }, result.AddedShowIds);
        Assert.Equal(1, result.AlreadySubscribed);
        var failure = Assert.Single(result.Failed);
        Assert.Equal("https://c.example/feed", failure.FeedUrl);

        _shows.Verify(s => s.GetOrCreateByFeedUrlAsync("https://a.example/feed", It.IsAny<CancellationToken>()), Times.Never);
        _subscriptions.Verify(s => s.SubscribeAsync(UserId, "show-a", It.IsAny<CancellationToken>()), Times.Never);
    }

    [Fact]
    public async Task ImportAsync_ResolvesLegacySubscriptionsWithoutASnapshotFeedUrlByReadingTheShow()
    {
        _subscriptions.Setup(s => s.GetSubscriptionsAsync(UserId, It.IsAny<CancellationToken>()))
            .ReturnsAsync(new[] { Sub("show-a", feedUrl: null) });
        _shows.Setup(s => s.TryGetFeedUrlAsync("show-a", It.IsAny<CancellationToken>()))
            .ReturnsAsync("https://a.example/feed");

        var result = await _sut.ImportAsync(UserId, Opml("https://a.example/feed"), CancellationToken.None);

        Assert.Equal(1, result.AlreadySubscribed);
        Assert.Equal(0, result.Added);
        _shows.Verify(s => s.GetOrCreateByFeedUrlAsync(It.IsAny<string>(), It.IsAny<CancellationToken>()), Times.Never);
    }

    [Fact]
    public async Task ImportAsync_CountsSubscribeReturningNullAsAFailure()
    {
        _shows.Setup(s => s.GetOrCreateByFeedUrlAsync("https://b.example/feed", It.IsAny<CancellationToken>()))
            .ReturnsAsync(ShowWithFeed("show-b", "https://b.example/feed"));
        _subscriptions.Setup(s => s.SubscribeAsync(UserId, "show-b", It.IsAny<CancellationToken>()))
            .ReturnsAsync((Subscription?)null);

        var result = await _sut.ImportAsync(UserId, Opml("https://b.example/feed"), CancellationToken.None);

        Assert.Equal(0, result.Added);
        var failure = Assert.Single(result.Failed);
        Assert.Equal("https://b.example/feed", failure.FeedUrl);
    }

    [Fact]
    public async Task ImportAsync_SubscribesOnlyOnceForAFeedListedTwiceInTheFile()
    {
        _shows.Setup(s => s.GetOrCreateByFeedUrlAsync("https://b.example/feed", It.IsAny<CancellationToken>()))
            .ReturnsAsync(ShowWithFeed("show-b", "https://b.example/feed"));
        _subscriptions.Setup(s => s.SubscribeAsync(UserId, "show-b", It.IsAny<CancellationToken>()))
            .ReturnsAsync(Sub("show-b", "https://b.example/feed"));

        var result = await _sut.ImportAsync(
            UserId,
            Opml("https://b.example/feed", "http://b.example/feed/"),
            CancellationToken.None);

        Assert.Equal(1, result.Added);
        _subscriptions.Verify(s => s.SubscribeAsync(UserId, "show-b", It.IsAny<CancellationToken>()), Times.Once);
    }

    [Fact]
    public async Task ImportAsync_OneFeedThrowing_IsRecordedAsAFailure_WithoutFailingTheWholeImport()
    {
        // ShowService only folds HttpRequestException / XmlException / TaskCanceledException into a
        // null return; a slow feed hitting the resilience pipeline's total-request timeout throws
        // a Polly TimeoutRejectedException that escapes it. Simulate any such escape here.
        _shows.Setup(s => s.GetOrCreateByFeedUrlAsync("https://slow.example/feed", It.IsAny<CancellationToken>()))
            .ThrowsAsync(new TimeoutException("The operation didn't complete within the allowed timeout."));

        _shows.Setup(s => s.GetOrCreateByFeedUrlAsync("https://good.example/feed", It.IsAny<CancellationToken>()))
            .ReturnsAsync(ShowWithFeed("show-good", "https://good.example/feed"));
        _subscriptions.Setup(s => s.SubscribeAsync(UserId, "show-good", It.IsAny<CancellationToken>()))
            .ReturnsAsync(Sub("show-good", "https://good.example/feed"));

        var result = await _sut.ImportAsync(
            UserId,
            Opml("https://slow.example/feed", "https://good.example/feed"),
            CancellationToken.None);

        Assert.Equal(new[] { "show-good" }, result.AddedShowIds);
        var failure = Assert.Single(result.Failed);
        Assert.Equal("https://slow.example/feed", failure.FeedUrl);
    }

    [Fact]
    public async Task ImportAsync_PropagatesFormatExceptionForAWholeDocumentThatIsInvalid()
    {
        await Assert.ThrowsAsync<FormatException>(
            () => _sut.ImportAsync(UserId, "<opml><body><outline ", CancellationToken.None));
    }
}
