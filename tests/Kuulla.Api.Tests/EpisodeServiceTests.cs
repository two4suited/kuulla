using Kuulla.Api.Models;
using Kuulla.Api.Services;
using Microsoft.Azure.Cosmos;
using Moq;

namespace Kuulla.Api.Tests;

public class EpisodeServiceTests
{
    private const string ShowId = "show-1";
    private const string UserId = "user-1";

    private readonly Mock<Container> _episodesContainer = new();
    private readonly Mock<Container> _subscriptionsContainer = new();
    private readonly Mock<IShowService> _showService = new();
    private readonly Mock<IPodcastFeedClient> _feedClient = new();
    private readonly Mock<ISettingsService> _settingsService = new();
    private readonly Mock<IEpisodeStateService> _episodeStateService = new();
    private readonly EpisodeService _sut;

    public EpisodeServiceTests()
    {
        _sut = new EpisodeService(
            _episodesContainer.Object,
            _subscriptionsContainer.Object,
            _showService.Object,
            _feedClient.Object,
            _settingsService.Object,
            _episodeStateService.Object);

        // No subscribers by default so the backfill tests (which trigger CacheEpisodesAsync)
        // don't need to stub enforcement — tests that care about it opt in explicitly.
        _subscriptionsContainer
            .Setup(c => c.GetItemQueryIterator<string>(It.IsAny<QueryDefinition>(), null, null))
            .Returns(CosmosTestHelpers.FeedIterator(Array.Empty<string>()));
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

    [Fact]
    public async Task EnforceUnlistenedLimitAsync_DoesNothingWhenLimitIsUnlimited()
    {
        _settingsService
            .Setup(s => s.GetEffectiveUnlistenedEpisodeCountAsync(UserId, ShowId, It.IsAny<CancellationToken>()))
            .ReturnsAsync(UnlistenedEpisodeCount.Unlimited);

        await _sut.EnforceUnlistenedLimitAsync(UserId, ShowId, CancellationToken.None);

        _episodesContainer.Verify(
            c => c.GetItemQueryIterator<Episode>(It.IsAny<QueryDefinition>(), null, It.IsAny<QueryRequestOptions>()), Times.Never);
    }

    [Fact]
    public async Task EnforceUnlistenedLimitAsync_MarksEpisodesBeyondLimitWithNoExistingStateAsAutoPlayed()
    {
        var episodes = Enumerable.Range(1, 5).Select(i => MakeEpisode(i.ToString())).ToList();
        SetupQuery(episodes);
        _settingsService
            .Setup(s => s.GetEffectiveUnlistenedEpisodeCountAsync(UserId, ShowId, It.IsAny<CancellationToken>()))
            .ReturnsAsync(UnlistenedEpisodeCount.Two);
        _episodeStateService
            .Setup(s => s.GetStateAsync(UserId, It.IsAny<string>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync((EpisodeState?)null);

        await _sut.EnforceUnlistenedLimitAsync(UserId, ShowId, CancellationToken.None);

        _episodeStateService.Verify(
            s => s.MarkAutoPlayedAsync(
                UserId,
                It.Is<IReadOnlyList<(string EpisodeId, string ShowId)>>(list =>
                    list.Select(x => x.EpisodeId).SequenceEqual(new[] { "3", "4", "5" })),
                It.IsAny<CancellationToken>()),
            Times.Once);
    }

    [Fact]
    public async Task EnforceUnlistenedLimitAsync_SkipsEpisodesThatAlreadyHaveState()
    {
        var episodes = Enumerable.Range(1, 3).Select(i => MakeEpisode(i.ToString())).ToList();
        SetupQuery(episodes);
        _settingsService
            .Setup(s => s.GetEffectiveUnlistenedEpisodeCountAsync(UserId, ShowId, It.IsAny<CancellationToken>()))
            .ReturnsAsync(UnlistenedEpisodeCount.One);
        _episodeStateService
            .Setup(s => s.GetStateAsync(UserId, "2", It.IsAny<CancellationToken>()))
            .ReturnsAsync(new EpisodeState("2", UserId, "2", ShowId, 50, false, DateTimeOffset.UtcNow));
        _episodeStateService
            .Setup(s => s.GetStateAsync(UserId, "3", It.IsAny<CancellationToken>()))
            .ReturnsAsync((EpisodeState?)null);

        await _sut.EnforceUnlistenedLimitAsync(UserId, ShowId, CancellationToken.None);

        _episodeStateService.Verify(
            s => s.MarkAutoPlayedAsync(
                UserId,
                It.Is<IReadOnlyList<(string EpisodeId, string ShowId)>>(list => list.Select(x => x.EpisodeId).SequenceEqual(new[] { "3" })),
                It.IsAny<CancellationToken>()),
            Times.Once);
    }

    [Fact]
    public async Task CacheEpisodesAsync_EnforcesLimitForEverySubscribedUser()
    {
        var show = new Show(ShowId, "Title", "Author", "https://feed.example/rss", null, null, []);
        var feedEpisode = MakeEpisode("new-1");

        _episodesContainer
            .SetupSequence(c => c.GetItemQueryIterator<Episode>(It.IsAny<QueryDefinition>(), null, It.IsAny<QueryRequestOptions>()))
            .Returns(CosmosTestHelpers.FeedIterator(Array.Empty<Episode>()))
            .Returns(CosmosTestHelpers.FeedIterator(new[] { feedEpisode }))
            .Returns(CosmosTestHelpers.FeedIterator(new[] { feedEpisode }));

        _showService.Setup(s => s.GetByIdAsync(ShowId, It.IsAny<CancellationToken>())).ReturnsAsync(show);
        _feedClient
            .Setup(c => c.FetchAsync(show.FeedUrl, It.IsAny<CancellationToken>()))
            .ReturnsAsync(new PodcastFeedContent(null, [feedEpisode]));
        _episodesContainer
            .Setup(c => c.CreateItemAsync(It.IsAny<Episode>(), It.IsAny<PartitionKey?>(), null, It.IsAny<CancellationToken>()))
            .ReturnsAsync((Episode e, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(e));
        _subscriptionsContainer
            .Setup(c => c.GetItemQueryIterator<string>(It.IsAny<QueryDefinition>(), null, null))
            .Returns(CosmosTestHelpers.FeedIterator(new[] { UserId }));
        _settingsService
            .Setup(s => s.GetEffectiveUnlistenedEpisodeCountAsync(UserId, ShowId, It.IsAny<CancellationToken>()))
            .ReturnsAsync(UnlistenedEpisodeCount.Unlimited);

        await _sut.GetEpisodesAsync(ShowId, continuationToken: null, pageSize: 20, CancellationToken.None);

        _settingsService.Verify(
            s => s.GetEffectiveUnlistenedEpisodeCountAsync(UserId, ShowId, It.IsAny<CancellationToken>()), Times.Once);
    }

    [Fact]
    public async Task CacheEpisodesAsync_SkipsEnforcementWhenNoEpisodesWereNewlyInserted()
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
        // Every insert conflicts — the episode already existed, nothing was actually newly cached.
        _episodesContainer
            .Setup(c => c.CreateItemAsync(It.IsAny<Episode>(), It.IsAny<PartitionKey?>(), null, It.IsAny<CancellationToken>()))
            .ThrowsAsync(CosmosTestHelpers.Conflict());

        await _sut.GetEpisodesAsync(ShowId, continuationToken: null, pageSize: 20, CancellationToken.None);

        _subscriptionsContainer.Verify(
            c => c.GetItemQueryIterator<string>(It.IsAny<QueryDefinition>(), null, null), Times.Never);
    }

    [Fact]
    public async Task EnforceAutoArchiveRuleAsync_DoesNothingWhenRuleIsNever()
    {
        _settingsService
            .Setup(s => s.GetEffectiveAutoArchiveRuleAsync(UserId, ShowId, It.IsAny<CancellationToken>()))
            .ReturnsAsync(AutoArchiveRule.Never);

        await _sut.EnforceAutoArchiveRuleAsync(UserId, ShowId, CancellationToken.None);

        _episodeStateService.Verify(
            s => s.GetShowStatesAsync(It.IsAny<string>(), It.IsAny<string>(), It.IsAny<CancellationToken>()), Times.Never);
    }

    [Fact]
    public async Task EnforceAutoArchiveRuleAsync_ArchivesPlayedEpisodesImmediatelyUnderAfterPlayedRule()
    {
        _settingsService
            .Setup(s => s.GetEffectiveAutoArchiveRuleAsync(UserId, ShowId, It.IsAny<CancellationToken>()))
            .ReturnsAsync(AutoArchiveRule.AfterPlayed);
        var played = new EpisodeState("ep-1", UserId, "ep-1", ShowId, 0, true, DateTimeOffset.UtcNow, PlayedAt: DateTimeOffset.UtcNow);
        var unplayed = new EpisodeState("ep-2", UserId, "ep-2", ShowId, 0, false, DateTimeOffset.UtcNow);
        _episodeStateService
            .Setup(s => s.GetShowStatesAsync(UserId, ShowId, It.IsAny<CancellationToken>()))
            .ReturnsAsync(new[] { played, unplayed });

        await _sut.EnforceAutoArchiveRuleAsync(UserId, ShowId, CancellationToken.None);

        _episodeStateService.Verify(
            s => s.SetArchivedAsync(
                UserId, It.Is<IReadOnlyList<string>>(list => list.SequenceEqual(new[] { "ep-1" })), true, It.IsAny<CancellationToken>()),
            Times.Once);
    }

    [Fact]
    public async Task EnforceAutoArchiveRuleAsync_SkipsEpisodesNotYetPastTheDelay()
    {
        _settingsService
            .Setup(s => s.GetEffectiveAutoArchiveRuleAsync(UserId, ShowId, It.IsAny<CancellationToken>()))
            .ReturnsAsync(AutoArchiveRule.After7Days);
        var recentlyPlayed = new EpisodeState(
            "ep-1", UserId, "ep-1", ShowId, 0, true, DateTimeOffset.UtcNow, PlayedAt: DateTimeOffset.UtcNow.AddDays(-1));
        var longPlayed = new EpisodeState(
            "ep-2", UserId, "ep-2", ShowId, 0, true, DateTimeOffset.UtcNow, PlayedAt: DateTimeOffset.UtcNow.AddDays(-8));
        _episodeStateService
            .Setup(s => s.GetShowStatesAsync(UserId, ShowId, It.IsAny<CancellationToken>()))
            .ReturnsAsync(new[] { recentlyPlayed, longPlayed });

        await _sut.EnforceAutoArchiveRuleAsync(UserId, ShowId, CancellationToken.None);

        _episodeStateService.Verify(
            s => s.SetArchivedAsync(
                UserId, It.Is<IReadOnlyList<string>>(list => list.SequenceEqual(new[] { "ep-2" })), true, It.IsAny<CancellationToken>()),
            Times.Once);
    }

    [Fact]
    public async Task EnforceAutoArchiveRuleAsync_SkipsAlreadyArchivedEpisodes()
    {
        _settingsService
            .Setup(s => s.GetEffectiveAutoArchiveRuleAsync(UserId, ShowId, It.IsAny<CancellationToken>()))
            .ReturnsAsync(AutoArchiveRule.AfterPlayed);
        var alreadyArchived = new EpisodeState(
            "ep-1", UserId, "ep-1", ShowId, 0, true, DateTimeOffset.UtcNow, PlayedAt: DateTimeOffset.UtcNow, Archived: true);
        _episodeStateService
            .Setup(s => s.GetShowStatesAsync(UserId, ShowId, It.IsAny<CancellationToken>()))
            .ReturnsAsync(new[] { alreadyArchived });

        await _sut.EnforceAutoArchiveRuleAsync(UserId, ShowId, CancellationToken.None);

        _episodeStateService.Verify(
            s => s.SetArchivedAsync(
                It.IsAny<string>(), It.Is<IReadOnlyList<string>>(list => list.Count == 0), true, It.IsAny<CancellationToken>()),
            Times.Once);
    }
}
