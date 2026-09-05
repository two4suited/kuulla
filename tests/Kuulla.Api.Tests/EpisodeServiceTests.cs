using Kuulla.Api.Models;
using Kuulla.Api.Services;
using Microsoft.Azure.Cosmos;
using Microsoft.Extensions.Logging.Abstractions;
using Moq;

namespace Kuulla.Api.Tests;

public class EpisodeServiceTests
{
    private const string ShowId = "show-1";
    private const string UserId = "user-1";

    private readonly Mock<Container> _episodesContainer = new();
    private readonly Mock<Container> _subscriptionsContainer = new();
    private readonly Mock<Container> _playlistsContainer = new();
    private readonly Mock<IShowService> _showService = new();
    private readonly Mock<IPodcastFeedClient> _feedClient = new();
    private readonly Mock<ISettingsService> _settingsService = new();
    private readonly Mock<IEpisodeStateService> _episodeStateService = new();
    private readonly Mock<IDeviceTokenService> _deviceTokenService = new();
    private readonly Mock<INotificationService> _notificationService = new();
    private readonly EpisodeService _sut;

    public EpisodeServiceTests()
    {
        _sut = new EpisodeService(
            _episodesContainer.Object,
            _subscriptionsContainer.Object,
            _playlistsContainer.Object,
            _showService.Object,
            _feedClient.Object,
            _settingsService.Object,
            _episodeStateService.Object,
            _deviceTokenService.Object,
            _notificationService.Object,
            NullLogger<EpisodeService>.Instance);

        // No subscribers by default so the backfill tests (which trigger CacheEpisodesAsync)
        // don't need to stub enforcement — tests that care about it opt in explicitly.
        _subscriptionsContainer
            .Setup(c => c.GetItemQueryIterator<string>(It.IsAny<QueryDefinition>(), null, null))
            .Returns(CosmosTestHelpers.FeedIterator(Array.Empty<string>()));

        // No dynamic playlists reference this show by default — tests covering auto-insert opt in
        // explicitly, same rationale as the subscriptions default above.
        _playlistsContainer
            .Setup(c => c.GetItemQueryIterator<Playlist>(It.IsAny<QueryDefinition>(), null, null))
            .Returns(CosmosTestHelpers.FeedIterator(Array.Empty<Playlist>()));
    }

    private static Episode MakeEpisode(string id) =>
        new(id, ShowId, $"Episode {id}", DateTimeOffset.UtcNow, TimeSpan.FromMinutes(30), $"https://audio.example/{id}.mp3", null, null, null);

    private static Episode MakeEpisode(string id, string showId, DateTimeOffset publishedAt) =>
        new(id, showId, $"Episode {id}", publishedAt, TimeSpan.FromMinutes(30), $"https://audio.example/{id}.mp3", null, null, null);

    private static Playlist MakeDynamicPlaylist(
        string userId, DynamicPlaylistConfig config, IReadOnlyList<PlaylistItem> items) =>
        new("playlist-1", userId, "Dynamic Playlist", PlaylistType.Dynamic, items,
            DateTimeOffset.UtcNow, DateTimeOffset.UtcNow, DynamicConfig: config);

    private void SetupEpisodeRead(Episode episode) =>
        _episodesContainer
            .Setup(c => c.ReadItemAsync<Episode>(episode.Id, It.IsAny<PartitionKey>(), null, It.IsAny<CancellationToken>()))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(episode));

    private void SetupSuccessfulCreate(params Episode[] episodes) =>
        _episodesContainer
            .Setup(c => c.CreateItemAsync(It.IsAny<Episode>(), It.IsAny<PartitionKey?>(), null, It.IsAny<CancellationToken>()))
            .ReturnsAsync((Episode e, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(e));

    // InsertIntoPlaylistWithRetryAsync re-reads the playlist by id/partition (for its ETag) before
    // every insert attempt rather than reusing the query result, so tests exercising the insert
    // path need this in addition to the GetItemQueryIterator<Playlist> discovery mock.
    private void SetupPlaylistRead(Playlist playlist) =>
        _playlistsContainer
            .Setup(c => c.ReadItemAsync<Playlist>(playlist.Id, It.IsAny<PartitionKey>(), null, It.IsAny<CancellationToken>()))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(playlist));

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
    public async Task CacheEpisodesAsync_NotifiesSubscriberWithNotificationsEnabledAndRegisteredDevices()
    {
        var show = new Show(ShowId, "Title", "Author", "https://feed.example/rss", null, null, []);
        var episode = MakeEpisode("new-1", ShowId, DateTimeOffset.UtcNow);
        var tokens = new[] { new DeviceToken("user-1:device-1", UserId, "device-1", "apns-token", DevicePlatform.Ios) };

        SetupSuccessfulCreate(episode);
        _subscriptionsContainer
            .Setup(c => c.GetItemQueryIterator<string>(It.IsAny<QueryDefinition>(), null, null))
            .Returns(CosmosTestHelpers.FeedIterator(new[] { UserId }));
        _showService.Setup(s => s.GetByIdAsync(ShowId, It.IsAny<CancellationToken>())).ReturnsAsync(show);
        _settingsService
            .Setup(s => s.GetEffectiveUnlistenedEpisodeCountAsync(UserId, ShowId, It.IsAny<CancellationToken>()))
            .ReturnsAsync(UnlistenedEpisodeCount.Unlimited);
        _settingsService
            .Setup(s => s.GetEffectiveNotificationsEnabledAsync(UserId, ShowId, It.IsAny<CancellationToken>()))
            .ReturnsAsync(true);
        _deviceTokenService
            .Setup(s => s.GetTokensForUserAsync(UserId, It.IsAny<CancellationToken>()))
            .ReturnsAsync(tokens);

        await _sut.CacheEpisodesAsync(ShowId, [episode], CancellationToken.None);

        _notificationService.Verify(
            s => s.NotifyNewEpisodesAsync(tokens, ShowId, show.Title, It.Is<IReadOnlyList<Episode>>(l => l.Single().Id == "new-1"), It.IsAny<CancellationToken>()),
            Times.Once);
    }

    [Fact]
    public async Task CacheEpisodesAsync_DoesNotNotifyWhenNotificationsDisabled()
    {
        var show = new Show(ShowId, "Title", "Author", "https://feed.example/rss", null, null, []);
        var episode = MakeEpisode("new-1", ShowId, DateTimeOffset.UtcNow);

        SetupSuccessfulCreate(episode);
        _subscriptionsContainer
            .Setup(c => c.GetItemQueryIterator<string>(It.IsAny<QueryDefinition>(), null, null))
            .Returns(CosmosTestHelpers.FeedIterator(new[] { UserId }));
        _showService.Setup(s => s.GetByIdAsync(ShowId, It.IsAny<CancellationToken>())).ReturnsAsync(show);
        _settingsService
            .Setup(s => s.GetEffectiveUnlistenedEpisodeCountAsync(UserId, ShowId, It.IsAny<CancellationToken>()))
            .ReturnsAsync(UnlistenedEpisodeCount.Unlimited);
        _settingsService
            .Setup(s => s.GetEffectiveNotificationsEnabledAsync(UserId, ShowId, It.IsAny<CancellationToken>()))
            .ReturnsAsync(false);

        await _sut.CacheEpisodesAsync(ShowId, [episode], CancellationToken.None);

        _deviceTokenService.Verify(s => s.GetTokensForUserAsync(It.IsAny<string>(), It.IsAny<CancellationToken>()), Times.Never);
        _notificationService.Verify(
            s => s.NotifyNewEpisodesAsync(
                It.IsAny<IReadOnlyList<DeviceToken>>(), It.IsAny<string>(), It.IsAny<string>(), It.IsAny<IReadOnlyList<Episode>>(), It.IsAny<CancellationToken>()),
            Times.Never);
    }

    [Fact]
    public async Task CacheEpisodesAsync_DoesNotNotifyWhenSubscriberHasNoRegisteredDevices()
    {
        var show = new Show(ShowId, "Title", "Author", "https://feed.example/rss", null, null, []);
        var episode = MakeEpisode("new-1", ShowId, DateTimeOffset.UtcNow);

        SetupSuccessfulCreate(episode);
        _subscriptionsContainer
            .Setup(c => c.GetItemQueryIterator<string>(It.IsAny<QueryDefinition>(), null, null))
            .Returns(CosmosTestHelpers.FeedIterator(new[] { UserId }));
        _showService.Setup(s => s.GetByIdAsync(ShowId, It.IsAny<CancellationToken>())).ReturnsAsync(show);
        _settingsService
            .Setup(s => s.GetEffectiveUnlistenedEpisodeCountAsync(UserId, ShowId, It.IsAny<CancellationToken>()))
            .ReturnsAsync(UnlistenedEpisodeCount.Unlimited);
        _settingsService
            .Setup(s => s.GetEffectiveNotificationsEnabledAsync(UserId, ShowId, It.IsAny<CancellationToken>()))
            .ReturnsAsync(true);
        _deviceTokenService
            .Setup(s => s.GetTokensForUserAsync(UserId, It.IsAny<CancellationToken>()))
            .ReturnsAsync(Array.Empty<DeviceToken>());

        await _sut.CacheEpisodesAsync(ShowId, [episode], CancellationToken.None);

        _notificationService.Verify(
            s => s.NotifyNewEpisodesAsync(
                It.IsAny<IReadOnlyList<DeviceToken>>(), It.IsAny<string>(), It.IsAny<string>(), It.IsAny<IReadOnlyList<Episode>>(), It.IsAny<CancellationToken>()),
            Times.Never);
    }

    [Fact]
    public async Task CacheEpisodesAsync_DoesNotNotifyForOldBackfilledEpisode()
    {
        // Simulates a show's whole back catalog landing as "newly inserted" the first time it's
        // fetched (a fresh subscribe, or the feed poller's first-ever sweep of this show) —
        // PublishedAt outside RecentEpisodeWindow means "backfill", not "genuinely just published",
        // so every subscriber shouldn't get notified about a show's entire history at once.
        var show = new Show(ShowId, "Title", "Author", "https://feed.example/rss", null, null, []);
        var oldEpisode = MakeEpisode("old-1", ShowId, DateTimeOffset.UtcNow.AddDays(-30));

        SetupSuccessfulCreate(oldEpisode);
        _subscriptionsContainer
            .Setup(c => c.GetItemQueryIterator<string>(It.IsAny<QueryDefinition>(), null, null))
            .Returns(CosmosTestHelpers.FeedIterator(new[] { UserId }));
        _showService.Setup(s => s.GetByIdAsync(ShowId, It.IsAny<CancellationToken>())).ReturnsAsync(show);
        _settingsService
            .Setup(s => s.GetEffectiveUnlistenedEpisodeCountAsync(UserId, ShowId, It.IsAny<CancellationToken>()))
            .ReturnsAsync(UnlistenedEpisodeCount.Unlimited);

        await _sut.CacheEpisodesAsync(ShowId, [oldEpisode], CancellationToken.None);

        _settingsService.Verify(
            s => s.GetEffectiveNotificationsEnabledAsync(It.IsAny<string>(), It.IsAny<string>(), It.IsAny<CancellationToken>()), Times.Never);
        _notificationService.Verify(
            s => s.NotifyNewEpisodesAsync(
                It.IsAny<IReadOnlyList<DeviceToken>>(), It.IsAny<string>(), It.IsAny<string>(), It.IsAny<IReadOnlyList<Episode>>(), It.IsAny<CancellationToken>()),
            Times.Never);
    }

    [Fact]
    public async Task CacheEpisodesAsync_DoesNotNotifyForFutureDatedEpisode()
    {
        // Some feeds publish a PublishedAt ahead of the actual release. Without an explicit
        // publishedAt <= now check, `now - publishedAt` is negative and still satisfies
        // `<= RecentEpisodeWindow`, which would incorrectly treat a not-yet-released episode as
        // "recent" and notify subscribers about content that isn't actually out yet.
        var show = new Show(ShowId, "Title", "Author", "https://feed.example/rss", null, null, []);
        var futureEpisode = MakeEpisode("future-1", ShowId, DateTimeOffset.UtcNow.AddDays(7));

        SetupSuccessfulCreate(futureEpisode);
        _subscriptionsContainer
            .Setup(c => c.GetItemQueryIterator<string>(It.IsAny<QueryDefinition>(), null, null))
            .Returns(CosmosTestHelpers.FeedIterator(new[] { UserId }));
        _showService.Setup(s => s.GetByIdAsync(ShowId, It.IsAny<CancellationToken>())).ReturnsAsync(show);
        _settingsService
            .Setup(s => s.GetEffectiveUnlistenedEpisodeCountAsync(UserId, ShowId, It.IsAny<CancellationToken>()))
            .ReturnsAsync(UnlistenedEpisodeCount.Unlimited);

        await _sut.CacheEpisodesAsync(ShowId, [futureEpisode], CancellationToken.None);

        _settingsService.Verify(
            s => s.GetEffectiveNotificationsEnabledAsync(It.IsAny<string>(), It.IsAny<string>(), It.IsAny<CancellationToken>()), Times.Never);
        _notificationService.Verify(
            s => s.NotifyNewEpisodesAsync(
                It.IsAny<IReadOnlyList<DeviceToken>>(), It.IsAny<string>(), It.IsAny<string>(), It.IsAny<IReadOnlyList<Episode>>(), It.IsAny<CancellationToken>()),
            Times.Never);
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
    public async Task CacheEpisodesAsync_InsertsNewEpisodeIntoDynamicPlaylistAtCorrectPosition()
    {
        var epoch = DateTimeOffset.UnixEpoch;
        var oldEpisode = MakeEpisode("old", ShowId, epoch);
        var newEpisode = MakeEpisode("new-1", ShowId, epoch.AddDays(1));
        var config = new DynamicPlaylistConfig(ShowIds: [ShowId], MaxEpisodes: null, PriorityList: [ShowId]);
        var playlist = MakeDynamicPlaylist(UserId, config, [new PlaylistItem("old", ShowId, epoch, "m")]);

        SetupSuccessfulCreate(newEpisode);
        SetupEpisodeRead(oldEpisode);
        SetupPlaylistRead(playlist);
        _playlistsContainer
            .Setup(c => c.GetItemQueryIterator<Playlist>(It.IsAny<QueryDefinition>(), null, null))
            .Returns(CosmosTestHelpers.FeedIterator(new[] { playlist }));

        Playlist? upserted = null;
        _playlistsContainer
            .Setup(c => c.UpsertItemAsync(It.IsAny<Playlist>(), It.IsAny<PartitionKey?>(), It.IsAny<ItemRequestOptions>(), It.IsAny<CancellationToken>()))
            .Callback<Playlist, PartitionKey?, ItemRequestOptions?, CancellationToken>((p, _, _, _) => upserted = p)
            .ReturnsAsync((Playlist p, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(p));

        await _sut.CacheEpisodesAsync(ShowId, [newEpisode], CancellationToken.None);

        Assert.NotNull(upserted);
        Assert.Equal(["new-1", "old"], upserted!.Items.Select(i => i.EpisodeId));
        Assert.Equal(upserted.Items.Select(i => i.Order).Order(StringComparer.Ordinal), upserted.Items.Select(i => i.Order));
    }

    [Fact]
    public async Task CacheEpisodesAsync_SkipsInsertWhenEpisodeAlreadyInPlaylist()
    {
        var episode = MakeEpisode("dup", ShowId, DateTimeOffset.UtcNow);
        var config = new DynamicPlaylistConfig(ShowIds: [ShowId], MaxEpisodes: null, PriorityList: [ShowId]);
        var playlist = MakeDynamicPlaylist(
            UserId, config, [new PlaylistItem("dup", ShowId, DateTimeOffset.UtcNow, "m")]);

        SetupSuccessfulCreate(episode);
        SetupPlaylistRead(playlist);
        _playlistsContainer
            .Setup(c => c.GetItemQueryIterator<Playlist>(It.IsAny<QueryDefinition>(), null, null))
            .Returns(CosmosTestHelpers.FeedIterator(new[] { playlist }));

        await _sut.CacheEpisodesAsync(ShowId, [episode], CancellationToken.None);

        _playlistsContainer.Verify(
            c => c.UpsertItemAsync(It.IsAny<Playlist>(), It.IsAny<PartitionKey?>(), It.IsAny<ItemRequestOptions>(), It.IsAny<CancellationToken>()), Times.Never);
    }

    [Fact]
    public async Task CacheEpisodesAsync_EvictsUnprotectedTailItemWhenMaxEpisodesExceeded()
    {
        var epoch = DateTimeOffset.UnixEpoch;
        var oldEpisode = MakeEpisode("old", ShowId, epoch);
        var midEpisode = MakeEpisode("mid", ShowId, epoch.AddDays(1));
        var newEpisode = MakeEpisode("new-1", ShowId, epoch.AddDays(2));
        var config = new DynamicPlaylistConfig(ShowIds: [ShowId], MaxEpisodes: 2, PriorityList: [ShowId]);
        var playlist = MakeDynamicPlaylist(UserId, config, [
            new PlaylistItem("mid", ShowId, epoch, "m"),
            new PlaylistItem("old", ShowId, epoch, "n"),
        ]);

        SetupSuccessfulCreate(newEpisode);
        SetupEpisodeRead(midEpisode);
        SetupEpisodeRead(oldEpisode);
        SetupPlaylistRead(playlist);
        _playlistsContainer
            .Setup(c => c.GetItemQueryIterator<Playlist>(It.IsAny<QueryDefinition>(), null, null))
            .Returns(CosmosTestHelpers.FeedIterator(new[] { playlist }));
        // "old" has in-progress playback and must never be evicted (#98's caution); "mid" doesn't,
        // so it's the one that gives up its slot once the cap is exceeded.
        _episodeStateService
            .Setup(s => s.GetStateAsync(UserId, "old", It.IsAny<CancellationToken>()))
            .ReturnsAsync(new EpisodeState("old", UserId, "old", ShowId, PositionSeconds: 120, Completed: false, UpdatedAt: DateTimeOffset.UtcNow));
        _episodeStateService
            .Setup(s => s.GetStateAsync(UserId, "mid", It.IsAny<CancellationToken>()))
            .ReturnsAsync((EpisodeState?)null);

        Playlist? upserted = null;
        _playlistsContainer
            .Setup(c => c.UpsertItemAsync(It.IsAny<Playlist>(), It.IsAny<PartitionKey?>(), It.IsAny<ItemRequestOptions>(), It.IsAny<CancellationToken>()))
            .Callback<Playlist, PartitionKey?, ItemRequestOptions?, CancellationToken>((p, _, _, _) => upserted = p)
            .ReturnsAsync((Playlist p, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(p));

        await _sut.CacheEpisodesAsync(ShowId, [newEpisode], CancellationToken.None);

        Assert.NotNull(upserted);
        Assert.Equal(["new-1", "old"], upserted!.Items.Select(i => i.EpisodeId));
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
                UserId, It.Is<IReadOnlyList<EpisodeState>>(list => list.Select(s => s.Id).SequenceEqual(new[] { "ep-1" })), true, It.IsAny<CancellationToken>()),
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
                UserId, It.Is<IReadOnlyList<EpisodeState>>(list => list.Select(s => s.Id).SequenceEqual(new[] { "ep-2" })), true, It.IsAny<CancellationToken>()),
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
                It.IsAny<string>(), It.Is<IReadOnlyList<EpisodeState>>(list => list.Count == 0), true, It.IsAny<CancellationToken>()),
            Times.Once);
    }
}
