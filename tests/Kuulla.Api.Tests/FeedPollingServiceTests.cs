using System.Net;
using Kuulla.Core.Models;
using Kuulla.Core.Services;
using Microsoft.Azure.Cosmos;
using Microsoft.Extensions.Logging;
using Moq;

namespace Kuulla.Api.Tests;

public class FeedPollingServiceTests
{
    private readonly Mock<ISubscriptionService> _subscriptionService = new();
    private readonly Mock<IShowService> _showService = new();
    private readonly Mock<IPodcastFeedClient> _feedClient = new();
    private readonly Mock<IEpisodeService> _episodeService = new();
    private readonly CapturingLogger<FeedPollingService> _logger = new();
    private readonly FeedPollingService _sut;

    public FeedPollingServiceTests()
    {
        _sut = new FeedPollingService(
            _subscriptionService.Object, _showService.Object, _feedClient.Object, _episodeService.Object,
            _logger);
    }

    // Minimal ILogger that keeps every formatted message, so a test can assert on the sweep
    // summary line without pulling in a mocking framework's awkward ILogger.Log verification.
    private sealed class CapturingLogger<T> : ILogger<T>
    {
        public List<string> Messages { get; } = [];

        public IDisposable? BeginScope<TState>(TState state) where TState : notnull => null;

        public bool IsEnabled(LogLevel logLevel) => true;

        public void Log<TState>(
            LogLevel logLevel, EventId eventId, TState state, Exception? exception,
            Func<TState, Exception?, string> formatter) => Messages.Add(formatter(state, exception));
    }

    private static Show MakeShow(string id, string feedUrl = "https://feed.example/rss") =>
        new(id, "Title", "Author", feedUrl, null, null, []);

    private static Episode MakeEpisode(string id, string showId) =>
        new(id, showId, "Title", DateTimeOffset.UtcNow, null, "https://audio.example/1.mp3", null, null, null);

    [Fact]
    public async Task PollOnceAsync_CachesEpisodesForEveryDistinctSubscribedShow()
    {
        _subscriptionService
            .Setup(s => s.GetDistinctSubscribedShowIdsAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(["show-a", "show-b"]);
        _showService.Setup(s => s.GetByIdAsync("show-a", It.IsAny<CancellationToken>())).ReturnsAsync(MakeShow("show-a", "https://feed.example/a"));
        _showService.Setup(s => s.GetByIdAsync("show-b", It.IsAny<CancellationToken>())).ReturnsAsync(MakeShow("show-b", "https://feed.example/b"));
        var episodesA = new[] { MakeEpisode("ep-a", "show-a") };
        var episodesB = new[] { MakeEpisode("ep-b", "show-b") };
        _feedClient.Setup(c => c.FetchAsync("https://feed.example/a", It.IsAny<CancellationToken>()))
            .ReturnsAsync(new PodcastFeedContent(null, episodesA));
        _feedClient.Setup(c => c.FetchAsync("https://feed.example/b", It.IsAny<CancellationToken>()))
            .ReturnsAsync(new PodcastFeedContent(null, episodesB));

        await _sut.PollOnceAsync(CancellationToken.None);

        _episodeService.Verify(
            s => s.CacheEpisodesAsync(It.IsAny<string>(), It.IsAny<IReadOnlyList<Episode>>(), It.IsAny<CancellationToken>()),
            Times.Exactly(2));
    }

    [Fact]
    public async Task PollOnceAsync_SkipsShowWithNoFeedUrl()
    {
        _subscriptionService
            .Setup(s => s.GetDistinctSubscribedShowIdsAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(["show-a"]);
        _showService.Setup(s => s.GetByIdAsync("show-a", It.IsAny<CancellationToken>())).ReturnsAsync(MakeShow("show-a", feedUrl: ""));

        await _sut.PollOnceAsync(CancellationToken.None);

        _feedClient.Verify(c => c.FetchAsync(It.IsAny<string>(), It.IsAny<CancellationToken>()), Times.Never);
        _episodeService.Verify(
            s => s.CacheEpisodesAsync(It.IsAny<string>(), It.IsAny<IReadOnlyList<Episode>>(), It.IsAny<CancellationToken>()), Times.Never);
    }

    [Fact]
    public async Task PollOnceAsync_SkipsShowWithMalformedFeedUrlInsteadOfThrowing()
    {
        _subscriptionService
            .Setup(s => s.GetDistinctSubscribedShowIdsAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(["show-a"]);
        _showService.Setup(s => s.GetByIdAsync("show-a", It.IsAny<CancellationToken>()))
            .ReturnsAsync(MakeShow("show-a", feedUrl: "not a valid url"));

        // Must not throw — an invalid FeedUrl reaching HttpClient would surface as
        // UriFormatException, which isn't in PollShowAsync's catch and would otherwise cancel
        // every other show still in flight in the same Parallel.ForEachAsync batch.
        await _sut.PollOnceAsync(CancellationToken.None);

        _feedClient.Verify(c => c.FetchAsync(It.IsAny<string>(), It.IsAny<CancellationToken>()), Times.Never);
    }

    [Fact]
    public async Task PollOnceAsync_SkipsShowThatNoLongerExists()
    {
        _subscriptionService
            .Setup(s => s.GetDistinctSubscribedShowIdsAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(["show-a"]);
        _showService.Setup(s => s.GetByIdAsync("show-a", It.IsAny<CancellationToken>())).ReturnsAsync((Show?)null);

        await _sut.PollOnceAsync(CancellationToken.None);

        _feedClient.Verify(c => c.FetchAsync(It.IsAny<string>(), It.IsAny<CancellationToken>()), Times.Never);
    }

    [Fact]
    public async Task PollOnceAsync_IsolatesOneShowsFeedFailureFromOthers()
    {
        _subscriptionService
            .Setup(s => s.GetDistinctSubscribedShowIdsAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(["show-a", "show-b"]);
        _showService.Setup(s => s.GetByIdAsync("show-a", It.IsAny<CancellationToken>()))
            .ReturnsAsync(MakeShow("show-a", "https://feed.example/a"));
        _showService.Setup(s => s.GetByIdAsync("show-b", It.IsAny<CancellationToken>()))
            .ReturnsAsync(MakeShow("show-b", "https://feed.example/b"));
        _feedClient.Setup(c => c.FetchAsync("https://feed.example/a", It.IsAny<CancellationToken>()))
            .ThrowsAsync(new HttpRequestException("feed unreachable"));
        _feedClient.Setup(c => c.FetchAsync("https://feed.example/b", It.IsAny<CancellationToken>()))
            .ReturnsAsync(new PodcastFeedContent(null, [MakeEpisode("ep-b", "show-b")]));

        await _sut.PollOnceAsync(CancellationToken.None);

        _episodeService.Verify(
            s => s.CacheEpisodesAsync("show-b", It.IsAny<IReadOnlyList<Episode>>(), It.IsAny<CancellationToken>()), Times.Once);
        _episodeService.Verify(
            s => s.CacheEpisodesAsync("show-a", It.IsAny<IReadOnlyList<Episode>>(), It.IsAny<CancellationToken>()), Times.Never);
    }

    [Fact]
    public async Task PollOnceAsync_IsolatesOneShowsCosmosFailureFromOthers()
    {
        _subscriptionService
            .Setup(s => s.GetDistinctSubscribedShowIdsAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(["show-a", "show-b"]);
        _showService.Setup(s => s.GetByIdAsync("show-a", It.IsAny<CancellationToken>()))
            .ReturnsAsync(MakeShow("show-a", "https://feed.example/a"));
        _showService.Setup(s => s.GetByIdAsync("show-b", It.IsAny<CancellationToken>()))
            .ReturnsAsync(MakeShow("show-b", "https://feed.example/b"));
        _feedClient.Setup(c => c.FetchAsync("https://feed.example/a", It.IsAny<CancellationToken>()))
            .ReturnsAsync(new PodcastFeedContent(null, [MakeEpisode("ep-a", "show-a")]));
        _feedClient.Setup(c => c.FetchAsync("https://feed.example/b", It.IsAny<CancellationToken>()))
            .ReturnsAsync(new PodcastFeedContent(null, [MakeEpisode("ep-b", "show-b")]));
        // A 429 that exhausts CacheEpisodesAsync's own retries (#558) shouldn't crash the whole
        // sweep — same isolation an unreachable feed already gets.
        _episodeService
            .Setup(s => s.CacheEpisodesAsync("show-a", It.IsAny<IReadOnlyList<Episode>>(), It.IsAny<CancellationToken>()))
            .ThrowsAsync(new CosmosException("Too many requests", HttpStatusCode.TooManyRequests, 3200, "activity-id", 0));

        await _sut.PollOnceAsync(CancellationToken.None);

        _episodeService.Verify(
            s => s.CacheEpisodesAsync("show-b", It.IsAny<IReadOnlyList<Episode>>(), It.IsAny<CancellationToken>()), Times.Once);
        Assert.Contains(_logger.Messages, m => m.StartsWith("Feed-poll sweep complete: 2 show(s), 1 unreachable/malformed,"));
    }

    [Fact]
    public async Task PollOnceAsync_SummaryLineReportsShowCountAndFeedFailureCount()
    {
        _subscriptionService
            .Setup(s => s.GetDistinctSubscribedShowIdsAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(["ok", "broken", "skipped"]);
        _showService.Setup(s => s.GetByIdAsync("ok", It.IsAny<CancellationToken>()))
            .ReturnsAsync(MakeShow("ok", "https://feed.example/ok"));
        _showService.Setup(s => s.GetByIdAsync("broken", It.IsAny<CancellationToken>()))
            .ReturnsAsync(MakeShow("broken", "https://feed.example/broken"));
        _showService.Setup(s => s.GetByIdAsync("skipped", It.IsAny<CancellationToken>()))
            .ReturnsAsync(MakeShow("skipped", feedUrl: ""));
        _feedClient.Setup(c => c.FetchAsync("https://feed.example/ok", It.IsAny<CancellationToken>()))
            .ReturnsAsync(new PodcastFeedContent(null, [MakeEpisode("ep", "ok")]));
        _feedClient.Setup(c => c.FetchAsync("https://feed.example/broken", It.IsAny<CancellationToken>()))
            .ThrowsAsync(new HttpRequestException("feed unreachable"));

        await _sut.PollOnceAsync(CancellationToken.None);

        // Only the unreachable feed counts as a failure; the empty-FeedUrl show is an intentional skip.
        Assert.Contains(_logger.Messages, m => m == "Feed-poll sweep starting: 3 subscribed show(s)");
        Assert.Contains(_logger.Messages, m => m.StartsWith("Feed-poll sweep complete: 3 show(s), 1 unreachable/malformed,"));
    }
}
