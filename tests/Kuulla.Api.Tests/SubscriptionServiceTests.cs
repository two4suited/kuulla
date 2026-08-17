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
    private readonly SubscriptionService _sut;

    public SubscriptionServiceTests()
    {
        _sut = new SubscriptionService(_subscriptionsContainer.Object, _showService.Object);
    }

    [Fact]
    public async Task GetSubscriptionsAsync_ReturnsAllPagesFromIterator()
    {
        var subscriptions = new[]
        {
            new Subscription("1", UserId, "1", "Show 1", "Author", null, DateTimeOffset.UtcNow),
            new Subscription("2", UserId, "2", "Show 2", "Author", null, DateTimeOffset.UtcNow),
        };
        _subscriptionsContainer
            .Setup(c => c.GetItemQueryIterator<Subscription>(It.IsAny<QueryDefinition>(), null, It.IsAny<QueryRequestOptions>()))
            .Returns(CosmosTestHelpers.FeedIterator(subscriptions));

        var results = await _sut.GetSubscriptionsAsync(UserId, CancellationToken.None);

        Assert.Equal(subscriptions, results);
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
}
