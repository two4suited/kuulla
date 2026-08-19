using Kuulla.Api.Models;
using Kuulla.Api.Services;
using Microsoft.Azure.Cosmos;
using Moq;
using Newtonsoft.Json;
using StackExchange.Redis;

namespace Kuulla.Api.Tests;

public class EpisodeStateServiceTests
{
    private const string UserId = "user-1";
    private const string ShowId = "show-1";

    private readonly Mock<Container> _episodeStatesContainer = new();
    private readonly Mock<IConnectionMultiplexer> _redis = new();
    private readonly Mock<IDatabase> _database = new();
    private readonly EpisodeStateService _sut;

    public EpisodeStateServiceTests()
    {
        _redis.Setup(r => r.GetDatabase(It.IsAny<int>(), It.IsAny<object>())).Returns(_database.Object);
        _sut = new EpisodeStateService(_episodeStatesContainer.Object, _redis.Object);

        // No hot cache entries or sync summaries pre-populated by default — every test below
        // opts in to a cache hit explicitly, so a miss (empty RedisValue) is the baseline.
        _database.Setup(d => d.StringGetAsync(It.IsAny<RedisKey>(), It.IsAny<CommandFlags>())).ReturnsAsync(RedisValue.Null);
    }

    private static EpisodeState MakeState(string episodeId, DateTimeOffset updatedAt, int position = 0, bool completed = false) =>
        new(episodeId, UserId, episodeId, ShowId, position, completed, updatedAt);

    [Fact]
    public async Task GetStateAsync_ReturnsHotCacheHitWithoutQueryingCosmos()
    {
        var cached = MakeState("ep-1", DateTimeOffset.UtcNow, position: 42);
        _database
            .Setup(d => d.StringGetAsync($"episodestate:{UserId}:ep-1", It.IsAny<CommandFlags>()))
            .ReturnsAsync(JsonConvert.SerializeObject(cached));

        var result = await _sut.GetStateAsync(UserId, "ep-1", CancellationToken.None);

        Assert.Equal(cached, result);
        _episodeStatesContainer.Verify(
            c => c.ReadItemAsync<EpisodeState>(It.IsAny<string>(), It.IsAny<PartitionKey>(), null, default), Times.Never);
    }

    [Fact]
    public async Task GetStateAsync_FallsBackToCosmosOnCacheMissAndPopulatesCache()
    {
        var stored = MakeState("ep-1", DateTimeOffset.UtcNow, position: 42);
        _episodeStatesContainer
            .Setup(c => c.ReadItemAsync<EpisodeState>("ep-1", It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(stored));

        var result = await _sut.GetStateAsync(UserId, "ep-1", CancellationToken.None);

        Assert.Equal(stored, result);
        _database.Verify(
            d => d.StringSetAsync(
                $"episodestate:{UserId}:ep-1", It.IsAny<RedisValue>(), It.IsAny<Expiration>(), It.IsAny<ValueCondition>(), It.IsAny<CommandFlags>()),
            Times.Once);
    }

    [Fact]
    public async Task GetStateAsync_ReturnsNullWhenNotFoundAnywhere()
    {
        _episodeStatesContainer
            .Setup(c => c.ReadItemAsync<EpisodeState>("ep-1", It.IsAny<PartitionKey>(), null, default))
            .ThrowsAsync(CosmosTestHelpers.NotFound());

        var result = await _sut.GetStateAsync(UserId, "ep-1", CancellationToken.None);

        Assert.Null(result);
    }

    [Fact]
    public async Task UpdateStateAsync_UpsertsWithServerStampedTimestamp()
    {
        SetupEmptyStatesQuery();
        EpisodeState? upserted = null;
        _episodeStatesContainer
            .Setup(c => c.UpsertItemAsync(It.IsAny<EpisodeState>(), It.IsAny<PartitionKey?>(), null, default))
            .Callback<EpisodeState, PartitionKey?, ItemRequestOptions?, CancellationToken>((s, _, _, _) => upserted = s)
            .ReturnsAsync((EpisodeState s, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(s));

        var before = DateTimeOffset.UtcNow;
        var result = await _sut.UpdateStateAsync(UserId, "ep-1", ShowId, 120, completed: true, deviceId: "device-a", CancellationToken.None);

        Assert.Equal("ep-1", result.Id);
        Assert.Equal(120, result.PositionSeconds);
        Assert.True(result.Completed);
        Assert.Equal("device-a", result.DeviceId);
        Assert.True(result.UpdatedAt >= before);
        Assert.Equal(result, upserted);
    }

    [Fact]
    public async Task MarkAutoPlayedAsync_UpsertsCompletedStateWithAutoPlayedFlag()
    {
        SetupEmptyStatesQuery();
        EpisodeState? upserted = null;
        _episodeStatesContainer
            .Setup(c => c.UpsertItemAsync(It.IsAny<EpisodeState>(), It.IsAny<PartitionKey?>(), null, default))
            .Callback<EpisodeState, PartitionKey?, ItemRequestOptions?, CancellationToken>((s, _, _, _) => upserted = s)
            .ReturnsAsync((EpisodeState s, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(s));

        var result = await _sut.MarkAutoPlayedAsync(UserId, "ep-1", ShowId, CancellationToken.None);

        Assert.Equal("ep-1", result.Id);
        Assert.True(result.Completed);
        Assert.True(result.AutoPlayed);
        Assert.Equal(0, result.PositionSeconds);
        Assert.Equal(result, upserted);
    }

    [Fact]
    public async Task SyncAsync_FastPathReturnsEmptyWhenHashMatchesAndNoChanges()
    {
        var summary = new SyncSummary("abc123", DateTimeOffset.UtcNow);
        _database
            .Setup(d => d.StringGetAsync($"sync:episodes:{UserId}", It.IsAny<CommandFlags>()))
            .ReturnsAsync(JsonConvert.SerializeObject(summary));

        var result = await _sut.SyncAsync(UserId, "device-a", DateTimeOffset.UtcNow.AddDays(-1), "abc123", [], CancellationToken.None);

        Assert.Empty(result.ServerChanges);
        Assert.Equal("abc123", result.Hash);
        _episodeStatesContainer.Verify(
            c => c.GetItemQueryIterator<EpisodeState>(It.IsAny<QueryDefinition>(), null, It.IsAny<QueryRequestOptions>()), Times.Never);
    }

    [Fact]
    public async Task SyncAsync_AcceptsChangeNewerThanStoredAndExcludesItFromDelta()
    {
        var lastSyncedAt = DateTimeOffset.UtcNow.AddHours(-2);
        var stored = MakeState("ep-1", DateTimeOffset.UtcNow.AddHours(-1), position: 10);
        _episodeStatesContainer
            .Setup(c => c.ReadItemAsync<EpisodeState>("ep-1", It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(stored));
        _episodeStatesContainer
            .Setup(c => c.UpsertItemAsync(It.IsAny<EpisodeState>(), It.IsAny<PartitionKey?>(), null, default))
            .ReturnsAsync((EpisodeState s, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(s));

        var accepted = MakeState("ep-1", DateTimeOffset.UtcNow, position: 99);
        SetupStatesQuery([accepted]);

        var change = new EpisodeStateChange("ep-1", ShowId, 99, false, DateTimeOffset.UtcNow);
        var result = await _sut.SyncAsync(UserId, "device-a", lastSyncedAt, "stale-hash", [change], CancellationToken.None);

        Assert.Empty(result.ServerChanges);
        _episodeStatesContainer.Verify(
            c => c.UpsertItemAsync(It.Is<EpisodeState>(s => s.EpisodeId == "ep-1" && s.PositionSeconds == 99), It.IsAny<PartitionKey?>(), null, default),
            Times.Once);
    }

    [Fact]
    public async Task SyncAsync_DiscardsChangeOlderThanStoredAndReturnsStoredAsDelta()
    {
        var lastSyncedAt = DateTimeOffset.UtcNow.AddHours(-2);
        var stored = MakeState("ep-1", DateTimeOffset.UtcNow, position: 500);
        _episodeStatesContainer
            .Setup(c => c.ReadItemAsync<EpisodeState>("ep-1", It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(stored));
        SetupStatesQuery([stored]);

        var staleChange = new EpisodeStateChange("ep-1", ShowId, 10, false, DateTimeOffset.UtcNow.AddHours(-1));
        var result = await _sut.SyncAsync(UserId, "device-a", lastSyncedAt, "stale-hash", [staleChange], CancellationToken.None);

        Assert.Single(result.ServerChanges);
        Assert.Equal(500, result.ServerChanges[0].PositionSeconds);
        _episodeStatesContainer.Verify(
            c => c.UpsertItemAsync(It.IsAny<EpisodeState>(), It.IsAny<PartitionKey?>(), null, default), Times.Never);
    }

    [Fact]
    public async Task SyncAsync_ExcludesRecordsNotChangedSinceLastSync()
    {
        var lastSyncedAt = DateTimeOffset.UtcNow.AddHours(-2);
        var untouched = MakeState("ep-old", lastSyncedAt.AddHours(-1), position: 1);
        SetupStatesQuery([untouched]);

        var result = await _sut.SyncAsync(UserId, "device-a", lastSyncedAt, "stale-hash", [], CancellationToken.None);

        Assert.Empty(result.ServerChanges);
    }

    private void SetupEmptyStatesQuery() => SetupStatesQuery([]);

    private void SetupStatesQuery(IReadOnlyList<EpisodeState> states) =>
        _episodeStatesContainer
            .Setup(c => c.GetItemQueryIterator<EpisodeState>(It.IsAny<QueryDefinition>(), null, It.IsAny<QueryRequestOptions>()))
            .Returns(CosmosTestHelpers.FeedIterator(states));
}
