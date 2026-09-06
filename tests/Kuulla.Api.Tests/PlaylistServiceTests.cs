using Kuulla.Api.Models;
using Kuulla.Api.Services;
using Microsoft.Azure.Cosmos;
using Moq;

namespace Kuulla.Api.Tests;

public class PlaylistServiceTests
{
    private const string UserId = "user-1";
    private const string PlaylistId = "playlist-1";
    private const string ShowId = "show-1";

    private readonly Mock<Container> _playlistsContainer = new();
    private readonly Mock<IEpisodeService> _episodeService = new();
    private readonly Mock<IEpisodeStateService> _episodeStateService = new();
    private readonly Mock<IShowService> _showService = new();
    private readonly PlaylistService _sut;

    public PlaylistServiceTests()
    {
        // Default: no episode has any saved state, so nothing is filtered as "played" — individual
        // tests override this to exercise the unplayed-only filter.
        _episodeStateService
            .Setup(s => s.GetShowStatesAsync(It.IsAny<string>(), It.IsAny<string>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync((IReadOnlyList<EpisodeState>)[]);

        _sut = new PlaylistService(
            _playlistsContainer.Object, _episodeService.Object, _episodeStateService.Object, _showService.Object);
    }

    private static Playlist MakePlaylist(
        string id = PlaylistId,
        string name = "My Playlist",
        IReadOnlyList<PlaylistItem>? items = null,
        DateTimeOffset? createdAt = null,
        DateTimeOffset? updatedAt = null) =>
        new(id, UserId, name, PlaylistType.Manual, items ?? [], createdAt ?? DateTimeOffset.UtcNow, updatedAt ?? DateTimeOffset.UtcNow);

    [Fact]
    public async Task GetPlaylistsAsync_ReturnsAllPagesFromIterator()
    {
        var page1 = new[] { MakePlaylist("1") };
        var page2 = new[] { MakePlaylist("2") };
        _playlistsContainer
            .Setup(c => c.GetItemQueryIterator<Playlist>(It.IsAny<QueryDefinition>(), null, It.IsAny<QueryRequestOptions>()))
            .Returns(CosmosTestHelpers.FeedIterator<Playlist>(page1, page2));

        var results = await _sut.GetPlaylistsAsync(UserId, CancellationToken.None);

        Assert.Equal(page1.Concat(page2), results);
    }

    [Fact]
    public async Task CreatePlaylistAsync_CreatesEmptyManualPlaylist()
    {
        Playlist? created = null;
        _playlistsContainer
            .Setup(c => c.UpsertItemAsync(It.IsAny<Playlist>(), It.IsAny<PartitionKey?>(), null, default))
            .Callback<Playlist, PartitionKey?, ItemRequestOptions?, CancellationToken>((p, _, _, _) => created = p)
            .ReturnsAsync((Playlist p, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(p));
        _playlistsContainer
            .Setup(c => c.GetItemQueryIterator<Playlist>(It.IsAny<QueryDefinition>(), null, It.IsAny<QueryRequestOptions>()))
            .Returns(() => CosmosTestHelpers.FeedIterator<Playlist>(
                (IReadOnlyList<Playlist>)(created is not null ? [created] : Array.Empty<Playlist>())));

        var result = await _sut.CreatePlaylistAsync(UserId, "New Playlist", null, null, CancellationToken.None);

        Assert.Equal(UserId, result.UserId);
        Assert.Equal("New Playlist", result.Name);
        Assert.Equal(PlaylistType.Manual, result.Type);
        Assert.Empty(result.Items);
    }

    [Fact]
    public async Task CreateDynamicPlaylistAsync_OrdersByPriorityThenPublishedAtAndTruncatesToMaxEpisodes()
    {
        const string showA = "show-a";
        const string showB = "show-b";
        var config = new DynamicPlaylistConfig(
            ShowIds: [showA, showB], MaxEpisodes: 3, PriorityList: [showB, showA]);

        // showB is higher priority, so its episodes (newest first) should lead, followed by
        // showA's, with the fourth episode overall dropped by the MaxEpisodes cap. Distinct
        // PublishedAt values (rather than all-UtcNow) make the within-show ordering meaningful —
        // GetAllEpisodesOrderedAsync's mocked return order stands in for its real PublishedAt DESC
        // query, and ComputeDynamicItemsAsync must preserve that order, not re-sort by anything else.
        var epoch = DateTimeOffset.UnixEpoch;
        _episodeService.Setup(s => s.GetAllEpisodesOrderedAsync(showA, It.IsAny<CancellationToken>()))
            .ReturnsAsync((IReadOnlyList<Episode>)[
                MakeEpisode("a-new", showA, epoch.AddDays(2)), MakeEpisode("a-old", showA, epoch.AddDays(1))]);
        _episodeService.Setup(s => s.GetAllEpisodesOrderedAsync(showB, It.IsAny<CancellationToken>()))
            .ReturnsAsync((IReadOnlyList<Episode>)[
                MakeEpisode("b-new", showB, epoch.AddDays(4)), MakeEpisode("b-old", showB, epoch.AddDays(3))]);
        SetUpEmptyQuery();

        Playlist? created = null;
        _playlistsContainer
            .Setup(c => c.UpsertItemAsync(It.IsAny<Playlist>(), It.IsAny<PartitionKey?>(), null, default))
            .Callback<Playlist, PartitionKey?, ItemRequestOptions?, CancellationToken>((p, _, _, _) => created = p)
            .ReturnsAsync((Playlist p, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(p));

        var result = await _sut.CreateDynamicPlaylistAsync(UserId, "Dynamic Playlist", config, null, null, CancellationToken.None);

        Assert.Equal(PlaylistType.Dynamic, result.Type);
        Assert.Equal(config, result.DynamicConfig);
        Assert.Equal(["b-new", "b-old", "a-new"], result.Items.Select(i => i.EpisodeId));
        Assert.Equal(result.Items.Select(i => i.Order).Order(StringComparer.Ordinal), result.Items.Select(i => i.Order));
        Assert.NotNull(created);
    }

    [Fact]
    public async Task CreateDynamicPlaylistAsync_WithNullMaxEpisodes_IncludesEveryEpisodeFromEveryShow()
    {
        const string showA = "show-a";
        const string showB = "show-b";
        var config = new DynamicPlaylistConfig(
            ShowIds: [showA, showB], MaxEpisodes: null, PriorityList: [showB, showA]);

        var epoch = DateTimeOffset.UnixEpoch;
        _episodeService.Setup(s => s.GetAllEpisodesOrderedAsync(showA, It.IsAny<CancellationToken>()))
            .ReturnsAsync((IReadOnlyList<Episode>)[
                MakeEpisode("a-new", showA, epoch.AddDays(2)), MakeEpisode("a-old", showA, epoch.AddDays(1))]);
        _episodeService.Setup(s => s.GetAllEpisodesOrderedAsync(showB, It.IsAny<CancellationToken>()))
            .ReturnsAsync((IReadOnlyList<Episode>)[
                MakeEpisode("b-new", showB, epoch.AddDays(4)), MakeEpisode("b-old", showB, epoch.AddDays(3))]);
        SetUpEmptyQuery();

        Playlist? created = null;
        _playlistsContainer
            .Setup(c => c.UpsertItemAsync(It.IsAny<Playlist>(), It.IsAny<PartitionKey?>(), null, default))
            .Callback<Playlist, PartitionKey?, ItemRequestOptions?, CancellationToken>((p, _, _, _) => created = p)
            .ReturnsAsync((Playlist p, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(p));

        var result = await _sut.CreateDynamicPlaylistAsync(UserId, "Dynamic Playlist", config, null, null, CancellationToken.None);

        Assert.Equal(["b-new", "b-old", "a-new", "a-old"], result.Items.Select(i => i.EpisodeId));
        Assert.NotNull(created);
    }

    [Fact]
    public async Task CreateDynamicPlaylistAsync_ExcludesCompletedAndAutoPlayedEpisodes()
    {
        var config = new DynamicPlaylistConfig(ShowIds: [ShowId], MaxEpisodes: null, PriorityList: [ShowId]);

        var epoch = DateTimeOffset.UnixEpoch;
        _episodeService.Setup(s => s.GetAllEpisodesOrderedAsync(ShowId, It.IsAny<CancellationToken>()))
            .ReturnsAsync((IReadOnlyList<Episode>)[
                MakeEpisode("unplayed", ShowId, epoch.AddDays(3)),
                MakeEpisode("completed", ShowId, epoch.AddDays(2)),
                MakeEpisode("auto-played", ShowId, epoch.AddDays(1))]);
        _episodeStateService
            .Setup(s => s.GetShowStatesAsync(UserId, ShowId, It.IsAny<CancellationToken>()))
            .ReturnsAsync((IReadOnlyList<EpisodeState>)[
                MakeState("completed", completed: true),
                MakeState("auto-played", autoPlayed: true)]);
        SetUpEmptyQuery();

        _playlistsContainer
            .Setup(c => c.UpsertItemAsync(It.IsAny<Playlist>(), It.IsAny<PartitionKey?>(), null, default))
            .ReturnsAsync((Playlist p, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(p));

        var result = await _sut.CreateDynamicPlaylistAsync(UserId, "Dynamic Playlist", config, null, null, CancellationToken.None);

        Assert.Equal(["unplayed"], result.Items.Select(i => i.EpisodeId));
    }

    [Fact]
    public async Task CreateDynamicPlaylistAsync_KeepsInProgressEpisodes()
    {
        var config = new DynamicPlaylistConfig(ShowIds: [ShowId], MaxEpisodes: null, PriorityList: [ShowId]);

        var epoch = DateTimeOffset.UnixEpoch;
        _episodeService.Setup(s => s.GetAllEpisodesOrderedAsync(ShowId, It.IsAny<CancellationToken>()))
            .ReturnsAsync((IReadOnlyList<Episode>)[
                MakeEpisode("in-progress", ShowId, epoch.AddDays(2)),
                MakeEpisode("fresh", ShowId, epoch.AddDays(1))]);
        _episodeStateService
            .Setup(s => s.GetShowStatesAsync(UserId, ShowId, It.IsAny<CancellationToken>()))
            .ReturnsAsync((IReadOnlyList<EpisodeState>)[MakeState("in-progress", positionSeconds: 300)]);
        SetUpEmptyQuery();

        _playlistsContainer
            .Setup(c => c.UpsertItemAsync(It.IsAny<Playlist>(), It.IsAny<PartitionKey?>(), null, default))
            .ReturnsAsync((Playlist p, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(p));

        var result = await _sut.CreateDynamicPlaylistAsync(UserId, "Dynamic Playlist", config, null, null, CancellationToken.None);

        Assert.Equal(["in-progress", "fresh"], result.Items.Select(i => i.EpisodeId));
    }

    private static EpisodeState MakeState(
        string episodeId, bool completed = false, bool autoPlayed = false, int positionSeconds = 0) =>
        new(episodeId, UserId, episodeId, ShowId, positionSeconds, completed, DateTimeOffset.UtcNow, AutoPlayed: autoPlayed);

    [Fact]
    public async Task UpdateDynamicPlaylistConfigAsync_ReturnsNullWhenPlaylistIsNotDynamic()
    {
        var playlist = MakePlaylist();
        _playlistsContainer
            .Setup(c => c.ReadItemAsync<Playlist>(PlaylistId, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(playlist));

        var config = new DynamicPlaylistConfig([ShowId], 10, [ShowId]);
        var result = await _sut.UpdateDynamicPlaylistConfigAsync(UserId, PlaylistId, config, CancellationToken.None);

        Assert.Null(result);
        _playlistsContainer.Verify(
            c => c.UpsertItemAsync(It.IsAny<Playlist>(), It.IsAny<PartitionKey?>(), null, default), Times.Never);
    }

    [Fact]
    public async Task UpdateDynamicPlaylistConfigAsync_RecomputesItemsFromNewConfig()
    {
        var oldConfig = new DynamicPlaylistConfig([ShowId], 10, [ShowId]);
        var playlist = new Playlist(
            PlaylistId, UserId, "Dynamic Playlist", PlaylistType.Dynamic,
            [new PlaylistItem("stale-episode", ShowId, DateTimeOffset.UtcNow, "m")],
            DateTimeOffset.UtcNow, DateTimeOffset.UtcNow, DynamicConfig: oldConfig);
        _playlistsContainer
            .Setup(c => c.ReadItemAsync<Playlist>(PlaylistId, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(playlist));
        _episodeService.Setup(s => s.GetAllEpisodesOrderedAsync(ShowId, It.IsAny<CancellationToken>()))
            .ReturnsAsync((IReadOnlyList<Episode>)[MakeEpisode("fresh-episode", ShowId)]);
        SetUpEmptyQuery();

        var newConfig = new DynamicPlaylistConfig([ShowId], 1, [ShowId]);
        var result = await _sut.UpdateDynamicPlaylistConfigAsync(UserId, PlaylistId, newConfig, CancellationToken.None);

        Assert.NotNull(result);
        Assert.Equal(newConfig, result!.DynamicConfig);
        var item = Assert.Single(result.Items);
        Assert.Equal("fresh-episode", item.EpisodeId);
    }

    [Fact]
    public async Task RecomputeDynamicPlaylistAsync_ReturnsNullForManualPlaylist()
    {
        var playlist = MakePlaylist();
        _playlistsContainer
            .Setup(c => c.ReadItemAsync<Playlist>(PlaylistId, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(playlist));

        var result = await _sut.RecomputeDynamicPlaylistAsync(UserId, PlaylistId, CancellationToken.None);

        Assert.Null(result);
    }

    private static Episode MakeEpisode(string id, string showId, DateTimeOffset? publishedAt = null) =>
        new(id, showId, id, publishedAt ?? DateTimeOffset.UtcNow, null, $"https://audio.example/{id}.mp3", null, null, null);

    [Fact]
    public async Task GetPlaylistDetailAsync_ReturnsNullWhenPlaylistDoesNotExist()
    {
        _playlistsContainer
            .Setup(c => c.ReadItemAsync<Playlist>(PlaylistId, It.IsAny<PartitionKey>(), null, default))
            .ThrowsAsync(CosmosTestHelpers.NotFound());

        var result = await _sut.GetPlaylistDetailAsync(UserId, PlaylistId, CancellationToken.None);

        Assert.Null(result);
    }

    [Fact]
    public async Task GetPlaylistDetailAsync_ResolvesEpisodeTitleAndShowArtworkPerItem()
    {
        var item = new PlaylistItem("episode-1", ShowId, DateTimeOffset.UtcNow, "m");
        var playlist = MakePlaylist(items: [item]);
        _playlistsContainer
            .Setup(c => c.ReadItemAsync<Playlist>(PlaylistId, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(playlist));

        var episode = new Episode("episode-1", ShowId, "Episode Title", DateTimeOffset.UtcNow, null, "https://audio.example/1.mp3", null, null, null);
        _episodeService.Setup(s => s.GetEpisodeAsync(ShowId, "episode-1", It.IsAny<CancellationToken>())).ReturnsAsync(episode);

        var show = CosmosTestHelpers.MakeShow(ShowId);
        _showService.Setup(s => s.GetByIdAsync(ShowId, It.IsAny<CancellationToken>())).ReturnsAsync(show);

        var result = await _sut.GetPlaylistDetailAsync(UserId, PlaylistId, CancellationToken.None);

        Assert.NotNull(result);
        var detailItem = Assert.Single(result!.Items);
        Assert.Equal("episode-1", detailItem.EpisodeId);
        Assert.Equal("Episode Title", detailItem.Title);
        Assert.Equal(show.ArtworkUrl, detailItem.ArtworkUrl);
    }

    [Fact]
    public async Task GetPlaylistDetailAsync_PrunesPlayedEpisodesFromDynamicPlaylistAndPersists()
    {
        var config = new DynamicPlaylistConfig([ShowId], MaxEpisodes: null, [ShowId]);
        var stored = new Playlist(
            PlaylistId, UserId, "Dynamic Playlist", PlaylistType.Dynamic,
            [
                new PlaylistItem("unplayed", ShowId, DateTimeOffset.UtcNow, "i"),
                new PlaylistItem("finished", ShowId, DateTimeOffset.UtcNow, "r"),
            ],
            DateTimeOffset.UtcNow, DateTimeOffset.UtcNow, DynamicConfig: config);
        _playlistsContainer
            .Setup(c => c.ReadItemAsync<Playlist>(PlaylistId, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(stored));
        _episodeService.Setup(s => s.GetAllEpisodesOrderedAsync(ShowId, It.IsAny<CancellationToken>()))
            .ReturnsAsync((IReadOnlyList<Episode>)[MakeEpisode("unplayed", ShowId), MakeEpisode("finished", ShowId)]);
        _episodeStateService
            .Setup(s => s.GetShowStatesAsync(UserId, ShowId, It.IsAny<CancellationToken>()))
            .ReturnsAsync((IReadOnlyList<EpisodeState>)[MakeState("finished", completed: true)]);
        _episodeService.Setup(s => s.GetEpisodeAsync(ShowId, "unplayed", It.IsAny<CancellationToken>()))
            .ReturnsAsync(MakeEpisode("unplayed", ShowId));
        _showService.Setup(s => s.GetByIdAsync(ShowId, It.IsAny<CancellationToken>()))
            .ReturnsAsync(CosmosTestHelpers.MakeShow(ShowId));
        _playlistsContainer
            .Setup(c => c.UpsertItemAsync(It.IsAny<Playlist>(), It.IsAny<PartitionKey?>(), null, default))
            .ReturnsAsync((Playlist p, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(p));

        var result = await _sut.GetPlaylistDetailAsync(UserId, PlaylistId, CancellationToken.None);

        Assert.NotNull(result);
        Assert.Equal(["unplayed"], result!.Items.Select(i => i.EpisodeId));
        _playlistsContainer.Verify(
            c => c.UpsertItemAsync(
                It.Is<Playlist>(p => p.Items.Select(i => i.EpisodeId).SequenceEqual(new[] { "unplayed" })),
                It.IsAny<PartitionKey?>(), null, default),
            Times.Once);
    }

    [Fact]
    public async Task GetPlaylistDetailAsync_DoesNotRewriteDynamicPlaylistWhenEpisodeSetUnchanged()
    {
        var config = new DynamicPlaylistConfig([ShowId], MaxEpisodes: null, [ShowId]);
        var stored = new Playlist(
            PlaylistId, UserId, "Dynamic Playlist", PlaylistType.Dynamic,
            [new PlaylistItem("only-episode", ShowId, DateTimeOffset.UnixEpoch, "some-stale-rank")],
            DateTimeOffset.UtcNow, DateTimeOffset.UtcNow, DynamicConfig: config);
        _playlistsContainer
            .Setup(c => c.ReadItemAsync<Playlist>(PlaylistId, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(stored));
        _episodeService.Setup(s => s.GetAllEpisodesOrderedAsync(ShowId, It.IsAny<CancellationToken>()))
            .ReturnsAsync((IReadOnlyList<Episode>)[MakeEpisode("only-episode", ShowId)]);
        _episodeService.Setup(s => s.GetEpisodeAsync(ShowId, "only-episode", It.IsAny<CancellationToken>()))
            .ReturnsAsync(MakeEpisode("only-episode", ShowId));
        _showService.Setup(s => s.GetByIdAsync(ShowId, It.IsAny<CancellationToken>()))
            .ReturnsAsync(CosmosTestHelpers.MakeShow(ShowId));

        var result = await _sut.GetPlaylistDetailAsync(UserId, PlaylistId, CancellationToken.None);

        Assert.NotNull(result);
        Assert.Equal(["only-episode"], result!.Items.Select(i => i.EpisodeId));
        _playlistsContainer.Verify(
            c => c.UpsertItemAsync(It.IsAny<Playlist>(), It.IsAny<PartitionKey?>(), null, default), Times.Never);
    }

    [Fact]
    public async Task RenamePlaylistAsync_ReturnsNullWhenPlaylistDoesNotExist()
    {
        _playlistsContainer
            .Setup(c => c.ReadItemAsync<Playlist>(PlaylistId, It.IsAny<PartitionKey>(), null, default))
            .ThrowsAsync(CosmosTestHelpers.NotFound());

        var result = await _sut.RenamePlaylistAsync(UserId, PlaylistId, "New Name", null, null, CancellationToken.None);

        Assert.Null(result);
    }

    [Fact]
    public async Task RenamePlaylistAsync_UpdatesNameAndTimestamp()
    {
        var playlist = MakePlaylist(name: "Old Name", updatedAt: DateTimeOffset.UtcNow.AddDays(-1));
        _playlistsContainer
            .Setup(c => c.ReadItemAsync<Playlist>(PlaylistId, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(playlist));
        SetUpEmptyQuery();

        var result = await _sut.RenamePlaylistAsync(UserId, PlaylistId, "New Name", null, null, CancellationToken.None);

        Assert.NotNull(result);
        Assert.Equal("New Name", result!.Name);
        Assert.True(result.UpdatedAt > playlist.UpdatedAt);
    }

    [Fact]
    public async Task CreatePlaylistAsync_PersistsIconAndAccentColor()
    {
        Playlist? created = null;
        _playlistsContainer
            .Setup(c => c.UpsertItemAsync(It.IsAny<Playlist>(), It.IsAny<PartitionKey?>(), null, default))
            .Callback<Playlist, PartitionKey?, ItemRequestOptions?, CancellationToken>((p, _, _, _) => created = p)
            .ReturnsAsync((Playlist p, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(p));

        var result = await _sut.CreatePlaylistAsync(UserId, "Workout", "💪", "#FF8800", CancellationToken.None);

        Assert.Equal("💪", result.Icon);
        Assert.Equal("#FF8800", result.AccentColor);
        Assert.Equal("💪", created!.Icon);
    }

    [Fact]
    public async Task RenamePlaylistAsync_UpdatesIconAndAccentColor()
    {
        var playlist = MakePlaylist(name: "Old Name") with { Icon = "🎧", AccentColor = "#111111" };
        _playlistsContainer
            .Setup(c => c.ReadItemAsync<Playlist>(PlaylistId, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(playlist));
        SetUpEmptyQuery();

        var result = await _sut.RenamePlaylistAsync(UserId, PlaylistId, "New Name", "🔥", null, CancellationToken.None);

        Assert.NotNull(result);
        Assert.Equal("🔥", result!.Icon);
        // A null accent colour clears it — the edit request carries the full desired state.
        Assert.Null(result.AccentColor);
    }

    [Fact]
    public async Task SyncAsync_PersistsIconFromAcceptedChange()
    {
        Playlist? upserted = null;
        _playlistsContainer
            .Setup(c => c.ReadItemAsync<Playlist>(PlaylistId, It.IsAny<PartitionKey>(), null, default))
            .ThrowsAsync(CosmosTestHelpers.NotFound());
        _playlistsContainer
            .Setup(c => c.UpsertItemAsync(It.IsAny<Playlist>(), It.IsAny<PartitionKey?>(), null, default))
            .Callback<Playlist, PartitionKey?, ItemRequestOptions?, CancellationToken>((p, _, _, _) => upserted = p)
            .ReturnsAsync((Playlist p, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(p));
        SetUpEmptyQuery();

        var change = new PlaylistChange(
            PlaylistId, "Synced Playlist", PlaylistType.Manual, [], DateTimeOffset.UtcNow, DateTimeOffset.UtcNow,
            Icon: "⭐", AccentColor: "#ABCDEF");

        await _sut.SyncAsync(UserId, "device-1", DateTimeOffset.MinValue, localHash: "", [change], CancellationToken.None);

        Assert.Equal("⭐", upserted!.Icon);
        Assert.Equal("#ABCDEF", upserted.AccentColor);
    }

    [Fact]
    public async Task DeletePlaylistAsync_IsIdempotentWhenAlreadyDeleted()
    {
        _playlistsContainer
            .Setup(c => c.DeleteItemAsync<Playlist>(PlaylistId, It.IsAny<PartitionKey>(), null, default))
            .ThrowsAsync(CosmosTestHelpers.NotFound());
        SetUpEmptyQuery();

        var exception = await Record.ExceptionAsync(() => _sut.DeletePlaylistAsync(UserId, PlaylistId, CancellationToken.None));

        Assert.Null(exception);
    }

    [Fact]
    public async Task AddItemAsync_AppendsWithRankAfterCurrentMax()
    {
        var existing = new PlaylistItem("episode-1", ShowId, DateTimeOffset.UtcNow, "m");
        var playlist = MakePlaylist(items: [existing]);
        _playlistsContainer
            .Setup(c => c.ReadItemAsync<Playlist>(PlaylistId, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(playlist));
        SetUpEmptyQuery();

        var result = await _sut.AddItemAsync(UserId, PlaylistId, "episode-2", ShowId, CancellationToken.None);

        Assert.NotNull(result);
        Assert.Equal(2, result!.Items.Count);
        var newItem = result.Items.Single(i => i.EpisodeId == "episode-2");
        Assert.True(string.CompareOrdinal(existing.Order, newItem.Order) < 0);
    }

    [Fact]
    public async Task AddItemAsync_IsIdempotentWhenEpisodeAlreadyInPlaylist()
    {
        var existing = new PlaylistItem("episode-1", ShowId, DateTimeOffset.UtcNow, "m");
        var playlist = MakePlaylist(items: [existing]);
        _playlistsContainer
            .Setup(c => c.ReadItemAsync<Playlist>(PlaylistId, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(playlist));

        var result = await _sut.AddItemAsync(UserId, PlaylistId, "episode-1", ShowId, CancellationToken.None);

        Assert.NotNull(result);
        Assert.Single(result!.Items);
        _playlistsContainer.Verify(
            c => c.UpsertItemAsync(It.IsAny<Playlist>(), It.IsAny<PartitionKey?>(), null, default), Times.Never);
    }

    [Fact]
    public async Task RemoveItemAsync_RemovesMatchingEpisode()
    {
        var item1 = new PlaylistItem("episode-1", ShowId, DateTimeOffset.UtcNow, "a");
        var item2 = new PlaylistItem("episode-2", ShowId, DateTimeOffset.UtcNow, "b");
        var playlist = MakePlaylist(items: [item1, item2]);
        _playlistsContainer
            .Setup(c => c.ReadItemAsync<Playlist>(PlaylistId, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(playlist));
        SetUpEmptyQuery();

        var result = await _sut.RemoveItemAsync(UserId, PlaylistId, "episode-1", CancellationToken.None);

        Assert.NotNull(result);
        var remaining = Assert.Single(result!.Items);
        Assert.Equal("episode-2", remaining.EpisodeId);
    }

    [Fact]
    public async Task RemoveItemAsync_IsIdempotentWhenEpisodeNotInPlaylist()
    {
        var existing = new PlaylistItem("episode-1", ShowId, DateTimeOffset.UtcNow, "a");
        var playlist = MakePlaylist(items: [existing]);
        _playlistsContainer
            .Setup(c => c.ReadItemAsync<Playlist>(PlaylistId, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(playlist));

        var result = await _sut.RemoveItemAsync(UserId, PlaylistId, "episode-not-present", CancellationToken.None);

        Assert.NotNull(result);
        Assert.Single(result!.Items);
        _playlistsContainer.Verify(
            c => c.UpsertItemAsync(It.IsAny<Playlist>(), It.IsAny<PartitionKey?>(), null, default), Times.Never);
    }

    [Fact]
    public async Task ReorderItemAsync_ComputesRankBetweenGivenNeighbors()
    {
        var item1 = new PlaylistItem("episode-1", ShowId, DateTimeOffset.UtcNow, "a");
        var item2 = new PlaylistItem("episode-2", ShowId, DateTimeOffset.UtcNow, "b");
        var item3 = new PlaylistItem("episode-3", ShowId, DateTimeOffset.UtcNow, "c");
        var playlist = MakePlaylist(items: [item1, item2, item3]);
        _playlistsContainer
            .Setup(c => c.ReadItemAsync<Playlist>(PlaylistId, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(playlist));
        SetUpEmptyQuery();

        // Move episode-3 between episode-1 and episode-2.
        var result = await _sut.ReorderItemAsync(
            UserId, PlaylistId, "episode-3", beforeEpisodeId: "episode-1", afterEpisodeId: "episode-2", CancellationToken.None);

        Assert.NotNull(result);
        Assert.Equal(["episode-1", "episode-3", "episode-2"], result!.Items.Select(i => i.EpisodeId));
    }

    [Fact]
    public async Task ReorderItemAsync_ThrowsWhenNeighborIdIsNotInThePlaylist()
    {
        var item1 = new PlaylistItem("episode-1", ShowId, DateTimeOffset.UtcNow, "a");
        var item2 = new PlaylistItem("episode-2", ShowId, DateTimeOffset.UtcNow, "b");
        var playlist = MakePlaylist(items: [item1, item2]);
        _playlistsContainer
            .Setup(c => c.ReadItemAsync<Playlist>(PlaylistId, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(playlist));

        await Assert.ThrowsAsync<ArgumentException>(() => _sut.ReorderItemAsync(
            UserId, PlaylistId, "episode-2", beforeEpisodeId: "episode-not-present", afterEpisodeId: null, CancellationToken.None));

        _playlistsContainer.Verify(
            c => c.UpsertItemAsync(It.IsAny<Playlist>(), It.IsAny<PartitionKey?>(), null, default), Times.Never);
    }

    [Fact]
    public async Task SyncAsync_AcceptsChangeNewerThanStoredAndExcludesItFromDelta()
    {
        _playlistsContainer
            .Setup(c => c.ReadItemAsync<Playlist>(PlaylistId, It.IsAny<PartitionKey>(), null, default))
            .ThrowsAsync(CosmosTestHelpers.NotFound());
        SetUpEmptyQuery();

        var change = new PlaylistChange(
            PlaylistId, "Synced Playlist", PlaylistType.Manual, [], DateTimeOffset.UtcNow, DateTimeOffset.UtcNow);

        var result = await _sut.SyncAsync(
            UserId, "device-1", DateTimeOffset.MinValue, localHash: "", [change], CancellationToken.None);

        Assert.Empty(result.ServerChanges);
        _playlistsContainer.Verify(
            c => c.UpsertItemAsync(It.Is<Playlist>(p => p.Id == PlaylistId), It.IsAny<PartitionKey?>(), null, default),
            Times.Once);
    }

    [Fact]
    public async Task SyncAsync_DiscardsChangeOlderThanStoredAndReturnsStoredAsDelta()
    {
        var stored = MakePlaylist(name: "Server Name", updatedAt: DateTimeOffset.UtcNow);
        _playlistsContainer
            .Setup(c => c.ReadItemAsync<Playlist>(PlaylistId, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(stored));
        _playlistsContainer
            .Setup(c => c.GetItemQueryIterator<Playlist>(It.IsAny<QueryDefinition>(), null, It.IsAny<QueryRequestOptions>()))
            .Returns(() => CosmosTestHelpers.FeedIterator<Playlist>((IReadOnlyList<Playlist>)[stored]));

        var staleChange = new PlaylistChange(
            PlaylistId, "Stale Name", PlaylistType.Manual, [], DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddDays(-1));

        var result = await _sut.SyncAsync(
            UserId, "device-1", DateTimeOffset.MinValue, localHash: "", [staleChange], CancellationToken.None);

        var serverChange = Assert.Single(result.ServerChanges);
        Assert.Equal("Server Name", serverChange.Name);
        _playlistsContainer.Verify(
            c => c.UpsertItemAsync(It.IsAny<Playlist>(), It.IsAny<PartitionKey?>(), null, default), Times.Never);
    }

    private void SetUpEmptyQuery() =>
        _playlistsContainer
            .Setup(c => c.GetItemQueryIterator<Playlist>(It.IsAny<QueryDefinition>(), null, It.IsAny<QueryRequestOptions>()))
            .Returns(() => CosmosTestHelpers.FeedIterator<Playlist>(Array.Empty<Playlist>()));
}
