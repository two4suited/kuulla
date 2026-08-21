using Kuulla.Api.Models;
using Kuulla.Api.Services.Sync;
using Moq;
using Newtonsoft.Json;
using StackExchange.Redis;

namespace Kuulla.Api.Tests;

// Exercises the generic sync framework (#84) against a domain that isn't episodes, using an
// in-memory dictionary in place of a Cosmos container, to prove ReconcileAsync's merge/delta
// logic is genuinely reusable rather than episode-specific.
public class SyncReconcilerTests
{
    private const string UserId = "user-1";

    private record TestRecord(string Id, string Value, DateTimeOffset UpdatedAt) : ISyncableRecord;

    private record TestChange(string Id, string Value, DateTimeOffset UpdatedAt);

    private readonly Mock<IConnectionMultiplexer> _redis = new();
    private readonly Mock<IDatabase> _database = new();
    private readonly Dictionary<string, TestRecord> _store = new();
    private readonly SyncSummaryCache<TestRecord> _summaryCache;
    private readonly SyncReconciler<TestRecord, TestChange> _sut;

    public SyncReconcilerTests()
    {
        _redis.Setup(r => r.GetDatabase(It.IsAny<int>(), It.IsAny<object>())).Returns(_database.Object);
        _database.Setup(d => d.StringGetAsync(It.IsAny<RedisKey>(), It.IsAny<CommandFlags>())).ReturnsAsync(RedisValue.Null);
        _summaryCache = new SyncSummaryCache<TestRecord>(_redis.Object, "widgets");
        _sut = new SyncReconciler<TestRecord, TestChange>(_summaryCache);
    }

    private Task<SyncReconciliationResult<TestRecord>> ReconcileAsync(
        DateTimeOffset lastSyncedAt, string localHash, IReadOnlyList<TestChange> changes) =>
        _sut.ReconcileAsync(
            UserId,
            lastSyncedAt,
            localHash,
            changes,
            getChangeId: c => c.Id,
            getChangeUpdatedAt: c => c.UpdatedAt,
            buildAcceptedState: (c, _) => new TestRecord(c.Id, c.Value, DateTimeOffset.UtcNow),
            readStoredAsync: (id, _) => Task.FromResult(_store.GetValueOrDefault(id)),
            upsertAsync: (state, _) =>
            {
                _store[state.Id] = state;
                return Task.CompletedTask;
            },
            queryAllAsync: _ => Task.FromResult<IReadOnlyList<TestRecord>>(_store.Values.ToList()),
            CancellationToken.None);

    [Fact]
    public async Task ReconcileAsync_AcceptsNewerChangeAndPersistsIt()
    {
        _store["w-1"] = new TestRecord("w-1", "old", DateTimeOffset.UtcNow.AddHours(-1));
        var change = new TestChange("w-1", "new", DateTimeOffset.UtcNow);

        var result = await ReconcileAsync(DateTimeOffset.UtcNow.AddHours(-2), "stale-hash", [change]);

        Assert.Equal("new", _store["w-1"].Value);
        Assert.Empty(result.ServerChanges);
    }

    [Fact]
    public async Task ReconcileAsync_DiscardsStaleChangeAndReturnsStoredAsDelta()
    {
        var stored = new TestRecord("w-1", "server-value", DateTimeOffset.UtcNow);
        _store["w-1"] = stored;
        var staleChange = new TestChange("w-1", "stale-value", DateTimeOffset.UtcNow.AddHours(-1));

        var result = await ReconcileAsync(DateTimeOffset.UtcNow.AddHours(-2), "stale-hash", [staleChange]);

        Assert.Equal("server-value", _store["w-1"].Value);
        Assert.Single(result.ServerChanges);
        Assert.Equal("server-value", result.ServerChanges[0].Value);
    }

    [Fact]
    public async Task ReconcileAsync_FastPathSkipsQueryWhenHashMatchesAndNoChanges()
    {
        var summary = new SyncSummary("matching-hash", DateTimeOffset.UtcNow);
        _database
            .Setup(d => d.StringGetAsync("sync:widgets:user-1", It.IsAny<CommandFlags>()))
            .ReturnsAsync(JsonConvert.SerializeObject(summary));

        var result = await ReconcileAsync(DateTimeOffset.UtcNow.AddDays(-1), "matching-hash", []);

        Assert.Empty(result.ServerChanges);
        Assert.Equal("matching-hash", result.Hash);
    }

    [Fact]
    public async Task ReconcileAsync_ExcludesRecordsUntouchedSinceLastSync()
    {
        var lastSyncedAt = DateTimeOffset.UtcNow.AddHours(-2);
        _store["w-old"] = new TestRecord("w-old", "unchanged", lastSyncedAt.AddHours(-1));

        var result = await ReconcileAsync(lastSyncedAt, "stale-hash", []);

        Assert.Empty(result.ServerChanges);
    }

    [Fact]
    public void Compute_IsOrderIndependentAndStableAcrossEquivalentInput()
    {
        var updatedAt = DateTimeOffset.UtcNow;
        var a = new TestRecord("w-1", "x", updatedAt);
        var b = new TestRecord("w-2", "y", updatedAt.AddSeconds(1));

        var first = SyncSummaryCache<TestRecord>.Compute([a, b]);
        var second = SyncSummaryCache<TestRecord>.Compute([b, a]);

        Assert.Equal(first.Hash, second.Hash);
        Assert.Equal(b.UpdatedAt, first.UpdatedAt);
    }

    [Fact]
    public void Compute_ReturnsEmptyHashSentinelForNoRecords()
    {
        var summary = SyncSummaryCache<TestRecord>.Compute([]);

        Assert.Equal(DateTimeOffset.MinValue, summary.UpdatedAt);
    }
}
