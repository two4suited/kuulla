using Kuulla.Api.Models;
using Kuulla.Api.Services;
using Microsoft.Azure.Cosmos;
using Moq;

namespace Kuulla.Api.Tests;

public class SubscriptionServiceTests
{
    private const string UserId = "user-1";
    private const string ShowId = "show-1";

    private readonly Mock<Container> _subscriptionsContainer = new();
    private readonly Mock<IShowService> _showService = new();
    private readonly Mock<IEpisodeService> _episodeService = new();
    private readonly Mock<IEpisodeStateService> _episodeStateService = new();
    private readonly SubscriptionService _sut;

    public SubscriptionServiceTests()
    {
        _sut = new SubscriptionService(
            _subscriptionsContainer.Object, _showService.Object, _episodeService.Object, _episodeStateService.Object);

        // SubscribeAsync reads the newest cached episode date to stamp
        // Subscription.LatestEpisodePublishedAt (#438); default to null so tests that don't care
        // about it are unaffected.
        _episodeService
            .Setup(s => s.GetNewestCachedEpisodePublishedAtAsync(It.IsAny<string>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync((DateTimeOffset?)null);
    }

    [Fact]
    public async Task GetSubscriptionsAsync_ReturnsAllPagesFromIterator()
    {
        // Two separate pages (not one list) so this actually exercises the service's
        // `while (iterator.HasMoreResults)` loop aggregating across multiple ReadNextAsync calls.
        var page1 = new[] { new Subscription("1", UserId, "1", "Show 1", "Author", null, DateTimeOffset.UtcNow) };
        var page2 = new[] { new Subscription("2", UserId, "2", "Show 2", "Author", null, DateTimeOffset.UtcNow) };
        _subscriptionsContainer
            .Setup(c => c.GetItemQueryIterator<Subscription>(It.IsAny<QueryDefinition>(), null, It.IsAny<QueryRequestOptions>()))
            .Returns(CosmosTestHelpers.FeedIterator<Subscription>(page1, page2));

        var results = await _sut.GetSubscriptionsAsync(UserId, CancellationToken.None);

        Assert.Equal(page1.Concat(page2), results);
    }

    [Fact]
    public async Task SubscribeAsync_ReturnsNullWhenShowDoesNotExist()
    {
        _showService.Setup(s => s.GetByIdAsync(ShowId, It.IsAny<CancellationToken>())).ReturnsAsync((Show?)null);

        var result = await _sut.SubscribeAsync(UserId, ShowId, CancellationToken.None);

        Assert.Null(result);
        _subscriptionsContainer.Verify(
            c => c.CreateItemAsync(It.IsAny<Subscription>(), It.IsAny<PartitionKey?>(), null, default),
            Times.Never);
    }

    [Fact]
    public async Task SubscribeAsync_CreatesSubscriptionMappedFromShow()
    {
        var show = CosmosTestHelpers.MakeShow(ShowId);
        _showService.Setup(s => s.GetByIdAsync(ShowId, It.IsAny<CancellationToken>())).ReturnsAsync(show);
        _subscriptionsContainer
            .Setup(c => c.CreateItemAsync(It.IsAny<Subscription>(), It.IsAny<PartitionKey?>(), null, default))
            .ReturnsAsync((Subscription s, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(s));

        var result = await _sut.SubscribeAsync(UserId, ShowId, CancellationToken.None);

        Assert.NotNull(result);
        Assert.Equal(ShowId, result!.Id);
        Assert.Equal(UserId, result.UserId);
        Assert.Equal(ShowId, result.ShowId);
        Assert.Equal(show.Title, result.ShowTitle);
        Assert.Equal(show.Author, result.ShowAuthor);
        Assert.Equal(show.ArtworkUrl, result.ShowArtworkUrl);
    }

    [Fact]
    public async Task SubscribeAsync_StampsLatestEpisodePublishedAtFromNewestEpisode()
    {
        var show = CosmosTestHelpers.MakeShow(ShowId);
        var newest = new DateTimeOffset(2026, 3, 1, 0, 0, 0, TimeSpan.Zero);
        _showService.Setup(s => s.GetByIdAsync(ShowId, It.IsAny<CancellationToken>())).ReturnsAsync(show);
        _episodeService
            .Setup(s => s.GetNewestCachedEpisodePublishedAtAsync(ShowId, It.IsAny<CancellationToken>()))
            .ReturnsAsync(newest);
        _subscriptionsContainer
            .Setup(c => c.CreateItemAsync(It.IsAny<Subscription>(), It.IsAny<PartitionKey?>(), null, default))
            .ReturnsAsync((Subscription s, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(s));

        var result = await _sut.SubscribeAsync(UserId, ShowId, CancellationToken.None);

        Assert.Equal(newest, result!.LatestEpisodePublishedAt);
    }

    [Fact]
    public async Task SubscribeAsync_LeavesLatestEpisodePublishedAtNullWhenShowHasNoEpisodes()
    {
        var show = CosmosTestHelpers.MakeShow(ShowId);
        _showService.Setup(s => s.GetByIdAsync(ShowId, It.IsAny<CancellationToken>())).ReturnsAsync(show);
        _subscriptionsContainer
            .Setup(c => c.CreateItemAsync(It.IsAny<Subscription>(), It.IsAny<PartitionKey?>(), null, default))
            .ReturnsAsync((Subscription s, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(s));

        var result = await _sut.SubscribeAsync(UserId, ShowId, CancellationToken.None);

        Assert.Null(result!.LatestEpisodePublishedAt);
    }

    [Fact]
    public async Task SubscribeAsync_ReturnsExistingSubscriptionOnConflictInsteadOfOverwriting()
    {
        var show = CosmosTestHelpers.MakeShow(ShowId);
        var existing = new Subscription(ShowId, UserId, ShowId, "Old Title", "Old Author", null, DateTimeOffset.UtcNow.AddDays(-5));
        _showService.Setup(s => s.GetByIdAsync(ShowId, It.IsAny<CancellationToken>())).ReturnsAsync(show);
        _subscriptionsContainer
            .Setup(c => c.CreateItemAsync(It.IsAny<Subscription>(), It.IsAny<PartitionKey?>(), null, default))
            .ThrowsAsync(CosmosTestHelpers.Conflict());
        _subscriptionsContainer
            .Setup(c => c.ReadItemAsync<Subscription>(ShowId, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(existing));

        var result = await _sut.SubscribeAsync(UserId, ShowId, CancellationToken.None);

        Assert.Equal(existing, result);
    }

    [Fact]
    public async Task UnsubscribeAsync_DeletesSubscription()
    {
        _subscriptionsContainer
            .Setup(c => c.DeleteItemAsync<Subscription>(ShowId, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse<Subscription>(null!));

        await _sut.UnsubscribeAsync(UserId, ShowId, CancellationToken.None);

        _subscriptionsContainer.Verify(c => c.DeleteItemAsync<Subscription>(ShowId, It.IsAny<PartitionKey>(), null, default), Times.Once);
    }

    [Fact]
    public async Task UnsubscribeAsync_IsIdempotentWhenAlreadyUnsubscribed()
    {
        _subscriptionsContainer
            .Setup(c => c.DeleteItemAsync<Subscription>(ShowId, It.IsAny<PartitionKey>(), null, default))
            .ThrowsAsync(CosmosTestHelpers.NotFound());

        var exception = await Record.ExceptionAsync(() => _sut.UnsubscribeAsync(UserId, ShowId, CancellationToken.None));

        Assert.Null(exception);
    }

    private static Episode MakeEpisode(string id, string showId, DateTimeOffset publishedAt) =>
        new(id, showId, $"Episode {id}", publishedAt, TimeSpan.FromMinutes(30), $"https://audio.example/{id}.mp3", null, null, null);

    [Fact]
    public async Task GetNewEpisodesAsync_ExcludesEpisodesWithExistingState()
    {
        var subscription = new Subscription(ShowId, UserId, ShowId, "Show 1", "Author", null, DateTimeOffset.UtcNow);
        _subscriptionsContainer
            .Setup(c => c.GetItemQueryIterator<Subscription>(It.IsAny<QueryDefinition>(), null, It.IsAny<QueryRequestOptions>()))
            .Returns(CosmosTestHelpers.FeedIterator<Subscription>([subscription]));

        var seen = MakeEpisode("seen", ShowId, DateTimeOffset.UtcNow);
        var unseen = MakeEpisode("unseen", ShowId, DateTimeOffset.UtcNow.AddDays(-1));
        _episodeService
            .Setup(s => s.GetEpisodesAsync(ShowId, null, It.IsAny<int>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync(new EpisodePage([seen, unseen], null));

        _episodeStateService
            .Setup(s => s.GetStateAsync(UserId, "seen", It.IsAny<CancellationToken>()))
            .ReturnsAsync(new EpisodeState("seen", UserId, "seen", ShowId, 10, false, DateTimeOffset.UtcNow));
        _episodeStateService
            .Setup(s => s.GetStateAsync(UserId, "unseen", It.IsAny<CancellationToken>()))
            .ReturnsAsync((EpisodeState?)null);

        var results = await _sut.GetNewEpisodesAsync(UserId, CancellationToken.None);

        Assert.Single(results);
        Assert.Equal("unseen", results[0].Episode.Id);
        Assert.False(results[0].AutoPlayed);
    }

    [Fact]
    public async Task GetNewEpisodesAsync_IncludesAutoPlayedEpisodesWithFlagSet()
    {
        var subscription = new Subscription(ShowId, UserId, ShowId, "Show 1", "Author", null, DateTimeOffset.UtcNow);
        _subscriptionsContainer
            .Setup(c => c.GetItemQueryIterator<Subscription>(It.IsAny<QueryDefinition>(), null, It.IsAny<QueryRequestOptions>()))
            .Returns(CosmosTestHelpers.FeedIterator<Subscription>([subscription]));

        var autoPlayed = MakeEpisode("auto", ShowId, DateTimeOffset.UtcNow.AddDays(-1));
        _episodeService
            .Setup(s => s.GetEpisodesAsync(ShowId, null, It.IsAny<int>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync(new EpisodePage([autoPlayed], null));
        _episodeStateService
            .Setup(s => s.GetStateAsync(UserId, "auto", It.IsAny<CancellationToken>()))
            .ReturnsAsync(new EpisodeState("auto", UserId, "auto", ShowId, 0, true, DateTimeOffset.UtcNow, AutoPlayed: true));

        var results = await _sut.GetNewEpisodesAsync(UserId, CancellationToken.None);

        Assert.Single(results);
        Assert.Equal("auto", results[0].Episode.Id);
        Assert.True(results[0].AutoPlayed);
    }

    [Fact]
    public async Task GetNewEpisodesAsync_IncludesRestoredEpisodeWithNoProgress()
    {
        // A Restore write (UpdateStateAsync with positionSeconds: 0, completed: false) leaves a
        // state row with AutoPlayed=false and no progress — this must still count as "unseen" or
        // the episode silently vanishes right after being restored (#99).
        var subscription = new Subscription(ShowId, UserId, ShowId, "Show 1", "Author", null, DateTimeOffset.UtcNow);
        _subscriptionsContainer
            .Setup(c => c.GetItemQueryIterator<Subscription>(It.IsAny<QueryDefinition>(), null, It.IsAny<QueryRequestOptions>()))
            .Returns(CosmosTestHelpers.FeedIterator<Subscription>([subscription]));

        var restored = MakeEpisode("restored", ShowId, DateTimeOffset.UtcNow.AddDays(-1));
        _episodeService
            .Setup(s => s.GetEpisodesAsync(ShowId, null, It.IsAny<int>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync(new EpisodePage([restored], null));
        _episodeStateService
            .Setup(s => s.GetStateAsync(UserId, "restored", It.IsAny<CancellationToken>()))
            .ReturnsAsync(new EpisodeState("restored", UserId, "restored", ShowId, 0, false, DateTimeOffset.UtcNow, AutoPlayed: false));

        var results = await _sut.GetNewEpisodesAsync(UserId, CancellationToken.None);

        Assert.Single(results);
        Assert.Equal("restored", results[0].Episode.Id);
        Assert.False(results[0].AutoPlayed);
    }

    [Fact]
    public async Task GetNewEpisodesAsync_MergesAcrossShowsSortedByPublishedAtDescending()
    {
        var subscriptionA = new Subscription("show-a", UserId, "show-a", "Show A", "Author", null, DateTimeOffset.UtcNow);
        var subscriptionB = new Subscription("show-b", UserId, "show-b", "Show B", "Author", null, DateTimeOffset.UtcNow);
        _subscriptionsContainer
            .Setup(c => c.GetItemQueryIterator<Subscription>(It.IsAny<QueryDefinition>(), null, It.IsAny<QueryRequestOptions>()))
            .Returns(CosmosTestHelpers.FeedIterator<Subscription>([subscriptionA, subscriptionB]));

        var older = MakeEpisode("older", "show-a", DateTimeOffset.UtcNow.AddDays(-2));
        var newer = MakeEpisode("newer", "show-b", DateTimeOffset.UtcNow.AddDays(-1));
        _episodeService
            .Setup(s => s.GetEpisodesAsync("show-a", null, It.IsAny<int>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync(new EpisodePage([older], null));
        _episodeService
            .Setup(s => s.GetEpisodesAsync("show-b", null, It.IsAny<int>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync(new EpisodePage([newer], null));
        _episodeStateService
            .Setup(s => s.GetStateAsync(UserId, It.IsAny<string>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync((EpisodeState?)null);

        var results = await _sut.GetNewEpisodesAsync(UserId, CancellationToken.None);

        Assert.Equal(["newer", "older"], results.Select(e => e.Episode.Id));
    }

    [Fact]
    public async Task GetNewEpisodesAsync_IsolatesOneShowsFeedFailureFromOthers()
    {
        var subscriptionA = new Subscription("show-a", UserId, "show-a", "Show A", "Author", null, DateTimeOffset.UtcNow);
        var subscriptionB = new Subscription("show-b", UserId, "show-b", "Show B", "Author", null, DateTimeOffset.UtcNow);
        _subscriptionsContainer
            .Setup(c => c.GetItemQueryIterator<Subscription>(It.IsAny<QueryDefinition>(), null, It.IsAny<QueryRequestOptions>()))
            .Returns(CosmosTestHelpers.FeedIterator<Subscription>([subscriptionA, subscriptionB]));

        var healthy = MakeEpisode("healthy", "show-b", DateTimeOffset.UtcNow);
        _episodeService
            .Setup(s => s.GetEpisodesAsync("show-a", null, It.IsAny<int>(), It.IsAny<CancellationToken>()))
            .ThrowsAsync(new HttpRequestException("feed unreachable"));
        _episodeService
            .Setup(s => s.GetEpisodesAsync("show-b", null, It.IsAny<int>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync(new EpisodePage([healthy], null));
        _episodeStateService
            .Setup(s => s.GetStateAsync(UserId, It.IsAny<string>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync((EpisodeState?)null);

        var results = await _sut.GetNewEpisodesAsync(UserId, CancellationToken.None);

        Assert.Equal(["healthy"], results.Select(e => e.Episode.Id));
    }

    [Fact]
    public async Task GetDistinctSubscribedShowIdsAsync_ReturnsAllPagesFromIterator()
    {
        _subscriptionsContainer
            .Setup(c => c.GetItemQueryIterator<string>(It.IsAny<QueryDefinition>(), null, null))
            .Returns(CosmosTestHelpers.FeedIterator<string>(["show-a"], ["show-b"]));

        var results = await _sut.GetDistinctSubscribedShowIdsAsync(CancellationToken.None);

        Assert.Equal(["show-a", "show-b"], results);
    }
}
