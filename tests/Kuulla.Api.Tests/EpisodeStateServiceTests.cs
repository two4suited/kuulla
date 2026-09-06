using Kuulla.Core.Models;
using Kuulla.Core.Services;
using Microsoft.Azure.Cosmos;
using Moq;

namespace Kuulla.Api.Tests;

public class EpisodeStateServiceTests
{
    private const string UserId = "user-1";
    private const string ShowId = "show-1";

    private readonly Mock<Container> _episodeStatesContainer = new();
    private readonly EpisodeStateService _sut;

    public EpisodeStateServiceTests()
    {
        _sut = new EpisodeStateService(_episodeStatesContainer.Object);
    }

    private static EpisodeState MakeState(string episodeId, DateTimeOffset updatedAt, int position = 0, bool completed = false) =>
        new(episodeId, UserId, episodeId, ShowId, position, completed, updatedAt);

    [Fact]
    public async Task GetStateAsync_ReadsFromCosmos()
    {
        var stored = MakeState("ep-1", DateTimeOffset.UtcNow, position: 42);
        _episodeStatesContainer
            .Setup(c => c.ReadItemAsync<EpisodeState>("ep-1", It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(stored));

        var result = await _sut.GetStateAsync(UserId, "ep-1", CancellationToken.None);

        Assert.Equal(stored, result);
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
        _episodeStatesContainer
            .Setup(c => c.ReadItemAsync<EpisodeState>("ep-1", It.IsAny<PartitionKey>(), null, default))
            .ThrowsAsync(CosmosTestHelpers.NotFound());
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
        Assert.NotNull(result.PlayedAt);
        Assert.Equal(result, upserted);
    }

    [Fact]
    public async Task UpdateStateAsync_PreservesPlayedAtWhenAlreadyPlayed()
    {
        var playedAt = DateTimeOffset.UtcNow.AddDays(-3);
        var existing = MakeState("ep-1", DateTimeOffset.UtcNow.AddDays(-3), position: 500, completed: true) with { PlayedAt = playedAt };
        _episodeStatesContainer
            .Setup(c => c.ReadItemAsync<EpisodeState>("ep-1", It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(existing));
        _episodeStatesContainer
            .Setup(c => c.UpsertItemAsync(It.IsAny<EpisodeState>(), It.IsAny<PartitionKey?>(), null, default))
            .ReturnsAsync((EpisodeState s, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(s));

        var result = await _sut.UpdateStateAsync(UserId, "ep-1", ShowId, 500, completed: true, deviceId: "device-a", CancellationToken.None);

        Assert.Equal(playedAt, result.PlayedAt);
    }

    [Fact]
    public async Task UpdateStateAsync_ClearsPlayedAtAndArchivedWhenMarkedUnplayed()
    {
        var existing = MakeState("ep-1", DateTimeOffset.UtcNow.AddDays(-3), position: 500, completed: true)
            with
        { PlayedAt = DateTimeOffset.UtcNow.AddDays(-3), Archived = true };
        _episodeStatesContainer
            .Setup(c => c.ReadItemAsync<EpisodeState>("ep-1", It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(existing));
        _episodeStatesContainer
            .Setup(c => c.UpsertItemAsync(It.IsAny<EpisodeState>(), It.IsAny<PartitionKey?>(), null, default))
            .ReturnsAsync((EpisodeState s, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(s));

        var result = await _sut.UpdateStateAsync(UserId, "ep-1", ShowId, 0, completed: false, deviceId: "device-a", CancellationToken.None);

        Assert.Null(result.PlayedAt);
        Assert.False(result.Archived);
    }

    [Fact]
    public async Task GetShowStatesAsync_ReturnsStatesFromScopedQuery()
    {
        var states = new[] { MakeState("ep-1", DateTimeOffset.UtcNow), MakeState("ep-2", DateTimeOffset.UtcNow) };
        SetupStatesQuery(states);

        var result = await _sut.GetShowStatesAsync(UserId, ShowId, CancellationToken.None);

        Assert.Equal(2, result.Count);
    }

    [Fact]
    public async Task SetArchivedAsync_ArchivesOnlyStatesNotAlreadyArchived()
    {
        var alreadyArchived = MakeState("ep-1", DateTimeOffset.UtcNow, completed: true) with { Archived = true };
        var notArchived = MakeState("ep-2", DateTimeOffset.UtcNow, completed: true);
        var upserted = new List<EpisodeState>();
        _episodeStatesContainer
            .Setup(c => c.UpsertItemAsync(It.IsAny<EpisodeState>(), It.IsAny<PartitionKey?>(), null, default))
            .Callback<EpisodeState, PartitionKey?, ItemRequestOptions?, CancellationToken>((s, _, _, _) => upserted.Add(s))
            .ReturnsAsync((EpisodeState s, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(s));

        await _sut.SetArchivedAsync(UserId, [alreadyArchived, notArchived], archived: true, CancellationToken.None);

        Assert.Single(upserted);
        Assert.Equal("ep-2", upserted[0].Id);
        Assert.True(upserted[0].Archived);
        _episodeStatesContainer.Verify(
            c => c.ReadItemAsync<EpisodeState>(It.IsAny<string>(), It.IsAny<PartitionKey>(), null, default), Times.Never);
    }

    [Fact]
    public async Task SetArchivedAsync_DoesNothingWhenEpisodeListIsEmpty()
    {
        await _sut.SetArchivedAsync(UserId, [], archived: true, CancellationToken.None);

        _episodeStatesContainer.Verify(
            c => c.UpsertItemAsync(It.IsAny<EpisodeState>(), It.IsAny<PartitionKey?>(), null, default), Times.Never);
    }

    [Fact]
    public async Task MarkAutoPlayedAsync_UpsertsCompletedStateWithAutoPlayedFlagForEachEpisode()
    {
        var upserted = new List<EpisodeState>();
        _episodeStatesContainer
            .Setup(c => c.UpsertItemAsync(It.IsAny<EpisodeState>(), It.IsAny<PartitionKey?>(), null, default))
            .Callback<EpisodeState, PartitionKey?, ItemRequestOptions?, CancellationToken>((s, _, _, _) => upserted.Add(s))
            .ReturnsAsync((EpisodeState s, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(s));

        await _sut.MarkAutoPlayedAsync(UserId, [("ep-1", ShowId), ("ep-2", ShowId)], CancellationToken.None);

        Assert.Equal(2, upserted.Count);
        Assert.All(upserted, s =>
        {
            Assert.True(s.Completed);
            Assert.True(s.AutoPlayed);
            Assert.Equal(0, s.PositionSeconds);
        });
        Assert.Equal(["ep-1", "ep-2"], upserted.Select(s => s.Id));
    }

    [Fact]
    public async Task MarkAutoPlayedAsync_DoesNothingWhenEpisodeListIsEmpty()
    {
        await _sut.MarkAutoPlayedAsync(UserId, [], CancellationToken.None);

        _episodeStatesContainer.Verify(
            c => c.UpsertItemAsync(It.IsAny<EpisodeState>(), It.IsAny<PartitionKey?>(), null, default), Times.Never);
    }

    [Fact]
    public async Task SyncAsync_FastPathReturnsEmptyWhenHashMatchesAndNoChanges()
    {
        var stored = MakeState("ep-1", DateTimeOffset.UtcNow.AddDays(-2), position: 10);
        SetupStatesQuery([stored]);
        var currentHash = SyncSummary.FromRecords<EpisodeState>([stored]).Hash;

        var result = await _sut.SyncAsync(
            UserId, "device-a", DateTimeOffset.UtcNow.AddDays(-1), currentHash, [], CancellationToken.None);

        Assert.Empty(result.ServerChanges);
        Assert.Equal(currentHash, result.Hash);
        _episodeStatesContainer.Verify(
            c => c.UpsertItemAsync(It.IsAny<EpisodeState>(), It.IsAny<PartitionKey?>(), null, default), Times.Never);
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

    [Fact]
    public async Task SyncAsync_StampsPlayedAtWhenAcceptedChangeTransitionsToCompleted()
    {
        var lastSyncedAt = DateTimeOffset.UtcNow.AddHours(-2);
        _episodeStatesContainer
            .Setup(c => c.ReadItemAsync<EpisodeState>("ep-1", It.IsAny<PartitionKey>(), null, default))
            .ThrowsAsync(CosmosTestHelpers.NotFound());
        EpisodeState? upserted = null;
        _episodeStatesContainer
            .Setup(c => c.UpsertItemAsync(It.IsAny<EpisodeState>(), It.IsAny<PartitionKey?>(), null, default))
            .Callback<EpisodeState, PartitionKey?, ItemRequestOptions?, CancellationToken>((s, _, _, _) => upserted = s)
            .ReturnsAsync((EpisodeState s, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(s));
        SetupStatesQuery([]);

        var before = DateTimeOffset.UtcNow;
        var change = new EpisodeStateChange("ep-1", ShowId, 500, true, DateTimeOffset.UtcNow);
        await _sut.SyncAsync(UserId, "device-a", lastSyncedAt, "stale-hash", [change], CancellationToken.None);

        Assert.NotNull(upserted);
        Assert.True(upserted!.Completed);
        Assert.NotNull(upserted.PlayedAt);
        Assert.InRange(upserted.PlayedAt!.Value, before, DateTimeOffset.UtcNow);
        Assert.False(upserted.Archived);
    }

    [Fact]
    public async Task SyncAsync_PreservesPlayedAtAndArchivedWhenAcceptedChangeDoesNotAffectCompletion()
    {
        // A later position-only push (e.g. a scrub while re-listening) of an already-played,
        // already-archived episode must not clobber PlayedAt or silently un-archive it — the
        // #187 bug this regression test guards against.
        var lastSyncedAt = DateTimeOffset.UtcNow.AddHours(-2);
        var playedAt = DateTimeOffset.UtcNow.AddDays(-10);
        var stored = new EpisodeState(
            "ep-1", UserId, "ep-1", ShowId, 100, Completed: true, DateTimeOffset.UtcNow.AddHours(-1), DeviceId: null,
            PlayedAt: playedAt, Archived: true);
        _episodeStatesContainer
            .Setup(c => c.ReadItemAsync<EpisodeState>("ep-1", It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(stored));
        EpisodeState? upserted = null;
        _episodeStatesContainer
            .Setup(c => c.UpsertItemAsync(It.IsAny<EpisodeState>(), It.IsAny<PartitionKey?>(), null, default))
            .Callback<EpisodeState, PartitionKey?, ItemRequestOptions?, CancellationToken>((s, _, _, _) => upserted = s)
            .ReturnsAsync((EpisodeState s, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(s));
        SetupStatesQuery([]);

        var change = new EpisodeStateChange("ep-1", ShowId, 105, true, DateTimeOffset.UtcNow);
        await _sut.SyncAsync(UserId, "device-a", lastSyncedAt, "stale-hash", [change], CancellationToken.None);

        Assert.NotNull(upserted);
        Assert.Equal(playedAt, upserted!.PlayedAt);
        Assert.True(upserted.Archived);
    }

    [Fact]
    public async Task SyncAsync_ClearsPlayedAtAndArchivedWhenAcceptedChangeMarksUnplayed()
    {
        var lastSyncedAt = DateTimeOffset.UtcNow.AddHours(-2);
        var stored = new EpisodeState(
            "ep-1", UserId, "ep-1", ShowId, 500, Completed: true, DateTimeOffset.UtcNow.AddHours(-1), DeviceId: null,
            PlayedAt: DateTimeOffset.UtcNow.AddDays(-10), Archived: true);
        _episodeStatesContainer
            .Setup(c => c.ReadItemAsync<EpisodeState>("ep-1", It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(stored));
        EpisodeState? upserted = null;
        _episodeStatesContainer
            .Setup(c => c.UpsertItemAsync(It.IsAny<EpisodeState>(), It.IsAny<PartitionKey?>(), null, default))
            .Callback<EpisodeState, PartitionKey?, ItemRequestOptions?, CancellationToken>((s, _, _, _) => upserted = s)
            .ReturnsAsync((EpisodeState s, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(s));
        SetupStatesQuery([]);

        var change = new EpisodeStateChange("ep-1", ShowId, 0, false, DateTimeOffset.UtcNow);
        await _sut.SyncAsync(UserId, "device-a", lastSyncedAt, "stale-hash", [change], CancellationToken.None);

        Assert.NotNull(upserted);
        Assert.Null(upserted!.PlayedAt);
        Assert.False(upserted.Archived);
    }

    [Fact]
    public async Task GetInProgressShowIdsAsync_ReturnsDistinctShowIdsFromScopedQuery()
    {
        _episodeStatesContainer
            .Setup(c => c.GetItemQueryIterator<string>(It.IsAny<QueryDefinition>(), null, It.IsAny<QueryRequestOptions>()))
            .Returns(CosmosTestHelpers.FeedIterator<string>(["show-1", "show-2", "show-1"]));

        var result = await _sut.GetInProgressShowIdsAsync(UserId, CancellationToken.None);

        Assert.Equal(new[] { "show-1", "show-2" }, result.OrderBy(s => s));
    }

    private void SetupEmptyStatesQuery() => SetupStatesQuery([]);

    private void SetupStatesQuery(IReadOnlyList<EpisodeState> states) =>
        _episodeStatesContainer
            .Setup(c => c.GetItemQueryIterator<EpisodeState>(It.IsAny<QueryDefinition>(), null, It.IsAny<QueryRequestOptions>()))
            .Returns(CosmosTestHelpers.FeedIterator(states));
}
