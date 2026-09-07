using Kuulla.Core.Models;
using Kuulla.Core.Services;
using Microsoft.Azure.Cosmos;
using Moq;

namespace Kuulla.Api.Tests;

public class ShowServiceTests
{
    private readonly Mock<Container> _showsContainer = new();
    private readonly Mock<IPodcastDirectoryClient> _directoryClient = new();
    private readonly Mock<IPodcastFeedClient> _feedClient = new();
    private readonly ShowService _sut;

    public ShowServiceTests()
    {
        _sut = new ShowService(_showsContainer.Object, _directoryClient.Object, _feedClient.Object);
    }

    [Fact]
    public async Task SearchAsync_ReturnsDirectoryResultsAndCachesEachOne()
    {
        var shows = new[] { CosmosTestHelpers.MakeShow("1"), CosmosTestHelpers.MakeShow("2") };
        _directoryClient.Setup(c => c.SearchAsync("query", It.IsAny<CancellationToken>())).ReturnsAsync(shows);
        _showsContainer
            .Setup(c => c.CreateItemAsync(It.IsAny<Show>(), It.IsAny<PartitionKey?>(), null, default))
            .ReturnsAsync((Show s, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(s));

        var results = await _sut.SearchAsync("query", CancellationToken.None);

        Assert.Equal(shows, results);
        _showsContainer.Verify(c => c.CreateItemAsync(It.Is<Show>(s => s.Id == "1"), It.IsAny<PartitionKey?>(), null, default), Times.Once);
        _showsContainer.Verify(c => c.CreateItemAsync(It.Is<Show>(s => s.Id == "2"), It.IsAny<PartitionKey?>(), null, default), Times.Once);
    }

    [Fact]
    public async Task SearchAsync_SwallowsConflictWhenShowAlreadyCached()
    {
        var shows = new[] { CosmosTestHelpers.MakeShow("1") };
        _directoryClient.Setup(c => c.SearchAsync("query", It.IsAny<CancellationToken>())).ReturnsAsync(shows);
        _showsContainer
            .Setup(c => c.CreateItemAsync(It.IsAny<Show>(), It.IsAny<PartitionKey?>(), null, default))
            .ThrowsAsync(CosmosTestHelpers.Conflict());

        var results = await _sut.SearchAsync("query", CancellationToken.None);

        Assert.Equal(shows, results);
    }

    [Fact]
    public async Task GetByIdAsync_ReturnsNullWhenNotFound()
    {
        _showsContainer
            .Setup(c => c.ReadItemAsync<Show>("missing", It.IsAny<PartitionKey>(), null, default))
            .ThrowsAsync(CosmosTestHelpers.NotFound());

        var result = await _sut.GetByIdAsync("missing", CancellationToken.None);

        Assert.Null(result);
    }

    [Fact]
    public async Task GetByIdAsync_ReturnsCachedShowWithoutFetchingFeedWhenDescriptionAlreadyPresent()
    {
        var show = CosmosTestHelpers.MakeShow(description: "Already has a description");
        _showsContainer
            .Setup(c => c.ReadItemAsync<Show>(show.Id, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(show));

        var result = await _sut.GetByIdAsync(show.Id, CancellationToken.None);

        Assert.Equal(show, result);
        _feedClient.Verify(c => c.FetchAsync(It.IsAny<string>(), It.IsAny<CancellationToken>()), Times.Never);
    }

    [Fact]
    public async Task GetByIdAsync_ReturnsShowUnchangedWhenFeedUrlMissing()
    {
        var show = CosmosTestHelpers.MakeShow(description: null, feedUrl: "");
        _showsContainer
            .Setup(c => c.ReadItemAsync<Show>(show.Id, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(show));

        var result = await _sut.GetByIdAsync(show.Id, CancellationToken.None);

        Assert.Equal(show, result);
        _feedClient.Verify(c => c.FetchAsync(It.IsAny<string>(), It.IsAny<CancellationToken>()), Times.Never);
    }

    [Fact]
    public async Task GetByIdAsync_EnrichesAndPersistsDescriptionFromFeedWhenMissing()
    {
        var show = CosmosTestHelpers.MakeShow(description: null);
        _showsContainer
            .Setup(c => c.ReadItemAsync<Show>(show.Id, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(show));
        _feedClient
            .Setup(c => c.FetchAsync(show.FeedUrl, It.IsAny<CancellationToken>()))
            .ReturnsAsync(new PodcastFeedContent("Fetched from feed", []));
        _showsContainer
            .Setup(c => c.UpsertItemAsync(It.IsAny<Show>(), It.IsAny<PartitionKey?>(), null, default))
            .ReturnsAsync((Show s, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(s));

        var result = await _sut.GetByIdAsync(show.Id, CancellationToken.None);

        Assert.Equal("Fetched from feed", result?.Description);
        _showsContainer.Verify(
            c => c.UpsertItemAsync(It.Is<Show>(s => s.Description == "Fetched from feed"), It.IsAny<PartitionKey?>(), null, default),
            Times.Once);
    }

    [Fact]
    public async Task GetOrCreateByFeedUrlAsync_ReturnsExistingShowWithAPointReadWhenFeedAlreadyKnown()
    {
        var cached = CosmosTestHelpers.MakeShow("feed-abc", feedUrl: "https://feeds.example/show");
        _showsContainer
            .Setup(c => c.ReadItemAsync<Show>(It.IsAny<string>(), It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(cached));

        var result = await _sut.GetOrCreateByFeedUrlAsync("https://feeds.example/show", CancellationToken.None);

        Assert.Same(cached, result);
        _feedClient.Verify(c => c.FetchAsync(It.IsAny<string>(), It.IsAny<CancellationToken>()), Times.Never);
        _showsContainer.Verify(
            c => c.CreateItemAsync(It.IsAny<Show>(), It.IsAny<PartitionKey?>(), null, default), Times.Never);
    }

    [Fact]
    public async Task GetOrCreateByFeedUrlAsync_CreatesShowFromFeedMetadataOnMiss()
    {
        _showsContainer
            .Setup(c => c.ReadItemAsync<Show>(It.IsAny<string>(), It.IsAny<PartitionKey>(), null, default))
            .ThrowsAsync(CosmosTestHelpers.NotFound());
        _feedClient
            .Setup(c => c.FetchAsync("https://feeds.example/show", It.IsAny<CancellationToken>()))
            .ReturnsAsync(new PodcastFeedContent(
                "A description", [], Title: "The Show", Author: "The Host", ArtworkUrl: "https://art.example/a.png"));
        _showsContainer
            .Setup(c => c.CreateItemAsync(It.IsAny<Show>(), It.IsAny<PartitionKey?>(), null, default))
            .ReturnsAsync((Show s, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(s));

        var result = await _sut.GetOrCreateByFeedUrlAsync("https://feeds.example/show/", CancellationToken.None);

        Assert.NotNull(result);
        Assert.Equal("The Show", result!.Title);
        Assert.Equal("The Host", result.Author);
        Assert.Equal("https://art.example/a.png", result.ArtworkUrl);
        Assert.Equal("A description", result.Description);
        Assert.Equal("https://feeds.example/show", result.FeedUrl); // normalized (trailing slash gone)
        Assert.StartsWith("feed-", result.Id);
    }

    [Fact]
    public async Task GetOrCreateByFeedUrlAsync_EquivalentFeedUrlsCollapseToTheSameShowId()
    {
        _showsContainer
            .Setup(c => c.ReadItemAsync<Show>(It.IsAny<string>(), It.IsAny<PartitionKey>(), null, default))
            .ThrowsAsync(CosmosTestHelpers.NotFound());
        _feedClient
            .Setup(c => c.FetchAsync(It.IsAny<string>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync(new PodcastFeedContent(null, [], Title: "Show"));
        var createdIds = new List<string>();
        _showsContainer
            .Setup(c => c.CreateItemAsync(It.IsAny<Show>(), It.IsAny<PartitionKey?>(), null, default))
            .Callback((Show s, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => createdIds.Add(s.Id))
            .ReturnsAsync((Show s, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(s));

        await _sut.GetOrCreateByFeedUrlAsync("http://Feeds.Example/show/", CancellationToken.None);
        await _sut.GetOrCreateByFeedUrlAsync("https://feeds.example:443/show", CancellationToken.None);

        Assert.Equal(2, createdIds.Count);
        Assert.Equal(createdIds[0], createdIds[1]);
    }

    [Fact]
    public async Task GetOrCreateByFeedUrlAsync_ReturnsNullWhenFeedCannotBeFetched()
    {
        _showsContainer
            .Setup(c => c.ReadItemAsync<Show>(It.IsAny<string>(), It.IsAny<PartitionKey>(), null, default))
            .ThrowsAsync(CosmosTestHelpers.NotFound());
        _feedClient
            .Setup(c => c.FetchAsync(It.IsAny<string>(), It.IsAny<CancellationToken>()))
            .ThrowsAsync(new HttpRequestException("dead host"));

        var result = await _sut.GetOrCreateByFeedUrlAsync("https://dead.example/show", CancellationToken.None);

        Assert.Null(result);
        _showsContainer.Verify(
            c => c.CreateItemAsync(It.IsAny<Show>(), It.IsAny<PartitionKey?>(), null, default), Times.Never);
    }

    [Fact]
    public async Task GetOrCreateByFeedUrlAsync_ReturnsNullWhenFeedIsUnparseable()
    {
        _showsContainer
            .Setup(c => c.ReadItemAsync<Show>(It.IsAny<string>(), It.IsAny<PartitionKey>(), null, default))
            .ThrowsAsync(CosmosTestHelpers.NotFound());
        _feedClient
            .Setup(c => c.FetchAsync(It.IsAny<string>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync((PodcastFeedContent?)null);

        var result = await _sut.GetOrCreateByFeedUrlAsync("https://notafeed.example/page", CancellationToken.None);

        Assert.Null(result);
    }

    [Fact]
    public async Task GetOrCreateByFeedUrlAsync_ReturnsNullWithoutTouchingCosmosWhenFeedUrlIsNotFetchable()
    {
        var result = await _sut.GetOrCreateByFeedUrlAsync("not a real url", CancellationToken.None);

        Assert.Null(result);
        _showsContainer.Verify(
            c => c.ReadItemAsync<Show>(It.IsAny<string>(), It.IsAny<PartitionKey>(), null, default), Times.Never);
        _feedClient.Verify(c => c.FetchAsync(It.IsAny<string>(), It.IsAny<CancellationToken>()), Times.Never);
    }

    [Fact]
    public async Task GetByIdAsync_ReturnsShowUnchangedWhenFeedHasNoDescription()
    {
        var show = CosmosTestHelpers.MakeShow(description: null);
        _showsContainer
            .Setup(c => c.ReadItemAsync<Show>(show.Id, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(show));
        _feedClient
            .Setup(c => c.FetchAsync(show.FeedUrl, It.IsAny<CancellationToken>()))
            .ReturnsAsync(new PodcastFeedContent(null, []));

        var result = await _sut.GetByIdAsync(show.Id, CancellationToken.None);

        Assert.Equal(show, result);
        _showsContainer.Verify(c => c.UpsertItemAsync(It.IsAny<Show>(), It.IsAny<PartitionKey?>(), null, default), Times.Never);
    }
}
