using Kuulla.Api.Models;
using Kuulla.Api.Services;
using Microsoft.Azure.Cosmos;
using Moq;

namespace Kuulla.Api.Tests;

public class EpisodeServiceTests
{
    private const string ShowId = "show-1";

    private readonly Mock<Container> _episodesContainer = new();
    private readonly Mock<IShowService> _showService = new();
    private readonly Mock<IPodcastFeedClient> _feedClient = new();
    private readonly EpisodeService _sut;

    public EpisodeServiceTests()
    {
        _sut = new EpisodeService(_episodesContainer.Object, _showService.Object, _feedClient.Object);
    }

    private static Episode MakeEpisode(string id) =>
        new(id, ShowId, $"Episode {id}", DateTimeOffset.UtcNow, TimeSpan.FromMinutes(30), $"https://audio.example/{id}.mp3", null, null, null);

    private void SetupQuery(IReadOnlyList<Episode> items) =>
        _episodesContainer
            .Setup(c => c.GetItemQueryIterator<Episode>(It.IsAny<QueryDefinition>(), null, It.IsAny<QueryRequestOptions>()))
            .Returns(CosmosTestHelpers.FeedIterator(items));

    [Fact]
    public async Task GetEpisodesAsync_TrimsExtraItemAndReturnsNextTokenWhenMoreExist()
    {
        var episodes = Enumerable.Range(1, 21).Select(i => MakeEpisode(i.ToString())).ToList();
        SetupQuery(episodes); // pageSize+1 = 21 returned -> hasMore

        var page = await _sut.GetEpisodesAsync(ShowId, continuationToken: null, pageSize: 20, CancellationToken.None);

        Assert.Equal(20, page.Items.Count);
        Assert.Equal("20", page.ContinuationToken);
    }

    [Fact]
    public async Task GetEpisodesAsync_NoNextTokenWhenFewerThanPageSizeReturned()
    {
        var episodes = new[] { MakeEpisode("1"), MakeEpisode("2") };
        SetupQuery(episodes);

        var page = await _sut.GetEpisodesAsync(ShowId, continuationToken: null, pageSize: 20, CancellationToken.None);

        Assert.Equal(2, page.Items.Count);
        Assert.Null(page.ContinuationToken);
    }

    [Fact]
    public async Task GetEpisodesAsync_ContinuesFromParsedOffset()
    {
        var episodes = Enumerable.Range(1, 21).Select(i => MakeEpisode(i.ToString())).ToList();
        SetupQuery(episodes);

        var page = await _sut.GetEpisodesAsync(ShowId, continuationToken: "20", pageSize: 20, CancellationToken.None);

        Assert.Equal("40", page.ContinuationToken);
    }

    [Fact]
    public async Task GetEpisodesAsync_BackfillsFromFeedWhenFirstPageEmpty()
    {
        var show = new Show(ShowId, "Title", "Author", "https://feed.example/rss", null, null, []);
        var feedEpisode = MakeEpisode("new-1");

        _episodesContainer
            .SetupSequence(c => c.GetItemQueryIterator<Episode>(It.IsAny<QueryDefinition>(), null, It.IsAny<QueryRequestOptions>()))
            .Returns(CosmosTestHelpers.FeedIterator(Array.Empty<Episode>()))
            .Returns(CosmosTestHelpers.FeedIterator(new[] { feedEpisode }));

        _showService.Setup(s => s.GetByIdAsync(ShowId, It.IsAny<CancellationToken>())).ReturnsAsync(show);
        _feedClient
            .Setup(c => c.FetchAsync(show.FeedUrl, It.IsAny<CancellationToken>()))
            .ReturnsAsync(new PodcastFeedContent(null, [feedEpisode]));
        Episode? cachedEpisode = null;
        _episodesContainer
            .Setup(c => c.CreateItemAsync(It.IsAny<Episode>(), It.IsAny<PartitionKey?>(), null, It.IsAny<CancellationToken>()))
            .ReturnsAsync((Episode e, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) =>
            {
                cachedEpisode = e;
                return CosmosTestHelpers.ItemResponse(e);
            });

        var page = await _sut.GetEpisodesAsync(ShowId, continuationToken: null, pageSize: 20, CancellationToken.None);

        Assert.Single(page.Items);
        Assert.Equal("new-1", page.Items[0].Id);
        Assert.Equal("new-1", cachedEpisode?.Id);
    }

    [Fact]
    public async Task GetEpisodesAsync_ReturnsEmptyPageWhenShowHasNoFeedUrl()
    {
        var show = new Show(ShowId, "Title", "Author", "", null, null, []);
        SetupQuery(Array.Empty<Episode>());
        _showService.Setup(s => s.GetByIdAsync(ShowId, It.IsAny<CancellationToken>())).ReturnsAsync(show);

        var page = await _sut.GetEpisodesAsync(ShowId, continuationToken: null, pageSize: 20, CancellationToken.None);

        Assert.Empty(page.Items);
        _feedClient.Verify(c => c.FetchAsync(It.IsAny<string>(), It.IsAny<CancellationToken>()), Times.Never);
    }

    [Fact]
    public async Task GetEpisodesAsync_DoesNotBackfillWhenContinuationTokenProvided()
    {
        SetupQuery(Array.Empty<Episode>());

        var page = await _sut.GetEpisodesAsync(ShowId, continuationToken: "20", pageSize: 20, CancellationToken.None);

        Assert.Empty(page.Items);
        _showService.Verify(s => s.GetByIdAsync(It.IsAny<string>(), It.IsAny<CancellationToken>()), Times.Never);
    }

    [Fact]
    public async Task GetEpisodeAsync_ReturnsCachedEpisodeWithoutTouchingFeed()
    {
        var episode = MakeEpisode("1");
        _episodesContainer
            .Setup(c => c.ReadItemAsync<Episode>("1", It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(episode));

        var result = await _sut.GetEpisodeAsync(ShowId, "1", CancellationToken.None);

        Assert.Equal(episode, result);
        _showService.Verify(s => s.GetByIdAsync(It.IsAny<string>(), It.IsAny<CancellationToken>()), Times.Never);
    }

    [Fact]
    public async Task GetEpisodeAsync_BackfillsFromFeedWhenNotCached()
    {
        var show = new Show(ShowId, "Title", "Author", "https://feed.example/rss", null, null, []);
        var episode = MakeEpisode("1");

        _episodesContainer
            .SetupSequence(c => c.ReadItemAsync<Episode>("1", It.IsAny<PartitionKey>(), null, default))
            .ThrowsAsync(CosmosTestHelpers.NotFound())
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(episode));

        _showService.Setup(s => s.GetByIdAsync(ShowId, It.IsAny<CancellationToken>())).ReturnsAsync(show);
        _feedClient
            .Setup(c => c.FetchAsync(show.FeedUrl, It.IsAny<CancellationToken>()))
            .ReturnsAsync(new PodcastFeedContent(null, [episode]));
        _episodesContainer
            .Setup(c => c.CreateItemAsync(It.IsAny<Episode>(), It.IsAny<PartitionKey?>(), null, It.IsAny<CancellationToken>()))
            .ReturnsAsync((Episode e, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(e));

        var result = await _sut.GetEpisodeAsync(ShowId, "1", CancellationToken.None);

        Assert.Equal(episode, result);
    }

    [Fact]
    public async Task GetEpisodeAsync_ReturnsNullWhenShowHasNoFeedUrl()
    {
        var show = new Show(ShowId, "Title", "Author", "", null, null, []);
        _episodesContainer
            .Setup(c => c.ReadItemAsync<Episode>("1", It.IsAny<PartitionKey>(), null, default))
            .ThrowsAsync(CosmosTestHelpers.NotFound());
        _showService.Setup(s => s.GetByIdAsync(ShowId, It.IsAny<CancellationToken>())).ReturnsAsync(show);

        var result = await _sut.GetEpisodeAsync(ShowId, "1", CancellationToken.None);

        Assert.Null(result);
    }

    [Fact]
    public async Task GetEpisodeAsync_ReturnsNullWhenFeedHasNoEpisodes()
    {
        var show = new Show(ShowId, "Title", "Author", "https://feed.example/rss", null, null, []);
        _episodesContainer
            .Setup(c => c.ReadItemAsync<Episode>("1", It.IsAny<PartitionKey>(), null, default))
            .ThrowsAsync(CosmosTestHelpers.NotFound());
        _showService.Setup(s => s.GetByIdAsync(ShowId, It.IsAny<CancellationToken>())).ReturnsAsync(show);
        _feedClient
            .Setup(c => c.FetchAsync(show.FeedUrl, It.IsAny<CancellationToken>()))
            .ReturnsAsync(new PodcastFeedContent(null, []));

        var result = await _sut.GetEpisodeAsync(ShowId, "1", CancellationToken.None);

        Assert.Null(result);
    }
}
