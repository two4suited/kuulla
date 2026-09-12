using System.Net;
using Kuulla.Core.Models;
using Kuulla.Core.Services;
using Microsoft.Azure.Cosmos;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
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
            Options.Create(new FeedPollingOptions()), _logger);
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
        _feedClient.Setup(c => c.PollAsync("https://feed.example/a", It.IsAny<FeedPollCursor>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync(new FeedPollResult(false, new PodcastFeedContent(null, episodesA), null, null));
        _feedClient.Setup(c => c.PollAsync("https://feed.example/b", It.IsAny<FeedPollCursor>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync(new FeedPollResult(false, new PodcastFeedContent(null, episodesB), null, null));

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

        _feedClient.Verify(c => c.PollAsync(It.IsAny<string>(), It.IsAny<FeedPollCursor>(), It.IsAny<CancellationToken>()), Times.Never);
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

        _feedClient.Verify(c => c.PollAsync(It.IsAny<string>(), It.IsAny<FeedPollCursor>(), It.IsAny<CancellationToken>()), Times.Never);
    }

    [Fact]
    public async Task PollOnceAsync_SkipsShowThatNoLongerExists()
    {
        _subscriptionService
            .Setup(s => s.GetDistinctSubscribedShowIdsAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(["show-a"]);
        _showService.Setup(s => s.GetByIdAsync("show-a", It.IsAny<CancellationToken>())).ReturnsAsync((Show?)null);

        await _sut.PollOnceAsync(CancellationToken.None);

        _feedClient.Verify(c => c.PollAsync(It.IsAny<string>(), It.IsAny<FeedPollCursor>(), It.IsAny<CancellationToken>()), Times.Never);
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
        _feedClient.Setup(c => c.PollAsync("https://feed.example/a", It.IsAny<FeedPollCursor>(), It.IsAny<CancellationToken>()))
            .ThrowsAsync(new HttpRequestException("feed unreachable"));
        _feedClient.Setup(c => c.PollAsync("https://feed.example/b", It.IsAny<FeedPollCursor>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync(new FeedPollResult(false, new PodcastFeedContent(null, [MakeEpisode("ep-b", "show-b")]), null, null));

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
        _feedClient.Setup(c => c.PollAsync("https://feed.example/a", It.IsAny<FeedPollCursor>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync(new FeedPollResult(false, new PodcastFeedContent(null, [MakeEpisode("ep-a", "show-a")]), null, null));
        _feedClient.Setup(c => c.PollAsync("https://feed.example/b", It.IsAny<FeedPollCursor>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync(new FeedPollResult(false, new PodcastFeedContent(null, [MakeEpisode("ep-b", "show-b")]), null, null));
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
        _feedClient.Setup(c => c.PollAsync("https://feed.example/ok", It.IsAny<FeedPollCursor>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync(new FeedPollResult(false, new PodcastFeedContent(null, [MakeEpisode("ep", "ok")]), null, null));
        _feedClient.Setup(c => c.PollAsync("https://feed.example/broken", It.IsAny<FeedPollCursor>(), It.IsAny<CancellationToken>()))
            .ThrowsAsync(new HttpRequestException("feed unreachable"));

        await _sut.PollOnceAsync(CancellationToken.None);

        // Only the unreachable feed counts as a failure; the empty-FeedUrl show is an intentional skip.
        Assert.Contains(_logger.Messages, m => m == "Feed-poll sweep starting: 3 subscribed show(s)");
        Assert.Contains(_logger.Messages, m => m.StartsWith("Feed-poll sweep complete: 3 show(s), 1 unreachable/malformed,"));
    }

    [Fact]
    public async Task PollOnceAsync_SkipsCachingAndCursorUpdateWhenFeedIsNotModified()
    {
        _subscriptionService
            .Setup(s => s.GetDistinctSubscribedShowIdsAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(["show-a"]);
        var show = MakeShow("show-a", "https://feed.example/a") with { FeedEtag = "\"etag-1\"" };
        _showService.Setup(s => s.GetByIdAsync("show-a", It.IsAny<CancellationToken>())).ReturnsAsync(show);
        _feedClient.Setup(c => c.PollAsync("https://feed.example/a", It.IsAny<FeedPollCursor>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync(new FeedPollResult(true, null, "\"etag-1\"", null));

        await _sut.PollOnceAsync(CancellationToken.None);

        _episodeService.Verify(
            s => s.CacheEpisodesAsync(It.IsAny<string>(), It.IsAny<IReadOnlyList<Episode>>(), It.IsAny<CancellationToken>()),
            Times.Never);
        _showService.Verify(
            s => s.UpdateFeedPollCursorAsync(It.IsAny<string>(), It.IsAny<string?>(), It.IsAny<string?>(), It.IsAny<CancellationToken>()),
            Times.Never);
    }

    [Fact]
    public async Task PollOnceAsync_PassesSavedCursorAndCachedWatermarkToPollAsync()
    {
        _subscriptionService
            .Setup(s => s.GetDistinctSubscribedShowIdsAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(["show-a"]);
        var show = MakeShow("show-a", "https://feed.example/a") with
        {
            FeedEtag = "\"etag-1\"",
            FeedLastModified = "Wed, 01 Jan 2025 00:00:00 GMT",
        };
        var watermark = DateTimeOffset.Parse("2025-06-01T00:00:00Z");
        _showService.Setup(s => s.GetByIdAsync("show-a", It.IsAny<CancellationToken>())).ReturnsAsync(show);
        _episodeService.Setup(s => s.GetNewestCachedEpisodePublishedAtAsync("show-a", It.IsAny<CancellationToken>()))
            .ReturnsAsync(watermark);
        _feedClient.Setup(c => c.PollAsync("https://feed.example/a", It.IsAny<FeedPollCursor>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync(new FeedPollResult(true, null, "\"etag-1\"", "Wed, 01 Jan 2025 00:00:00 GMT"));

        await _sut.PollOnceAsync(CancellationToken.None);

        _feedClient.Verify(
            c => c.PollAsync(
                "https://feed.example/a",
                It.Is<FeedPollCursor>(cursor =>
                    cursor.ETag == "\"etag-1\""
                    && cursor.LastModified == "Wed, 01 Jan 2025 00:00:00 GMT"
                    && cursor.WatermarkPublishedAt == watermark),
                It.IsAny<CancellationToken>()),
            Times.Once);
    }

    [Fact]
    public async Task PollOnceAsync_PersistsNewCursorAfterASuccessfulFetch()
    {
        _subscriptionService
            .Setup(s => s.GetDistinctSubscribedShowIdsAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(["show-a"]);
        var show = MakeShow("show-a", "https://feed.example/a") with { FeedEtag = "\"old-etag\"" };
        _showService.Setup(s => s.GetByIdAsync("show-a", It.IsAny<CancellationToken>())).ReturnsAsync(show);
        _feedClient.Setup(c => c.PollAsync("https://feed.example/a", It.IsAny<FeedPollCursor>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync(new FeedPollResult(false, new PodcastFeedContent(null, [MakeEpisode("ep-a", "show-a")]), "\"new-etag\"", "Thu, 02 Jan 2025 00:00:00 GMT"));

        await _sut.PollOnceAsync(CancellationToken.None);

        _showService.Verify(
            s => s.UpdateFeedPollCursorAsync(
                "show-a", "\"new-etag\"", "Thu, 02 Jan 2025 00:00:00 GMT", It.IsAny<CancellationToken>()),
            Times.Once);
    }

    [Fact]
    public async Task PollOnceAsync_HonorsConfiguredMaxDegreeOfParallelism()
    {
        var sut = new FeedPollingService(
            _subscriptionService.Object, _showService.Object, _feedClient.Object, _episodeService.Object,
            Options.Create(new FeedPollingOptions { MaxDegreeOfParallelism = 1 }), _logger);
        _subscriptionService
            .Setup(s => s.GetDistinctSubscribedShowIdsAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(["show-a", "show-b", "show-c"]);
        foreach (var id in new[] { "show-a", "show-b", "show-c" })
        {
            _showService.Setup(s => s.GetByIdAsync(id, It.IsAny<CancellationToken>()))
                .ReturnsAsync(MakeShow(id, $"https://feed.example/{id}"));
        }

        var concurrentCalls = 0;
        var maxObservedConcurrency = 0;
        _feedClient
            .Setup(c => c.PollAsync(It.IsAny<string>(), It.IsAny<FeedPollCursor>(), It.IsAny<CancellationToken>()))
            .Returns(async () =>
            {
                var current = Interlocked.Increment(ref concurrentCalls);
                InterlockedMax(ref maxObservedConcurrency, current);
                await Task.Delay(20);
                Interlocked.Decrement(ref concurrentCalls);
                return new FeedPollResult(true, null, null, null);
            });

        await sut.PollOnceAsync(CancellationToken.None);

        // A MaxDegreeOfParallelism of 1 forces the three shows through PollShowAsync one at a
        // time — this only holds because FeedPollingService actually reads the configured value
        // (a hardcoded MaxDegreeOfParallelism would still pass this by coincidence at 15, but
        // fails obviously at 1).
        Assert.Equal(1, maxObservedConcurrency);
    }

    private static void InterlockedMax(ref int target, int candidate)
    {
        int initial;
        do
        {
            initial = target;
            if (candidate <= initial)
            {
                return;
            }
        } while (Interlocked.CompareExchange(ref target, candidate, initial) != initial);
    }

    [Fact]
    public async Task PollOnceAsync_DoesNotCacheEpisodesWhenPollReturnsNoEpisodes()
    {
        _subscriptionService
            .Setup(s => s.GetDistinctSubscribedShowIdsAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(["show-a"]);
        _showService.Setup(s => s.GetByIdAsync("show-a", It.IsAny<CancellationToken>()))
            .ReturnsAsync(MakeShow("show-a", "https://feed.example/a"));
        _feedClient.Setup(c => c.PollAsync("https://feed.example/a", It.IsAny<FeedPollCursor>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync(new FeedPollResult(false, new PodcastFeedContent(null, []), "\"etag\"", null));

        await _sut.PollOnceAsync(CancellationToken.None);

        _episodeService.Verify(
            s => s.CacheEpisodesAsync(It.IsAny<string>(), It.IsAny<IReadOnlyList<Episode>>(), It.IsAny<CancellationToken>()),
            Times.Never);
        // Still worth saving — the ETag changed even though every item was already known.
        _showService.Verify(
            s => s.UpdateFeedPollCursorAsync("show-a", "\"etag\"", null, It.IsAny<CancellationToken>()), Times.Once);
    }
}
