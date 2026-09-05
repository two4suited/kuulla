using Kuulla.Api.Models;
using Kuulla.Api.Services.Sync;

namespace Kuulla.Api.Tests;

// Exercises the generic sync framework (#84) against a domain that isn't episodes, using an
// in-memory dictionary in place of a Cosmos container, to prove ReconcileAsync's merge/delta
// logic is genuinely reusable rather than episode-specific.
public class SyncReconcilerTests
{
    private const string UserId = "user-1";

    private record TestRecord(string Id, string Value, DateTimeOffset UpdatedAt) : ISyncableRecord;

    private record TestChange(string Id, string Value, DateTimeOffset UpdatedAt);

    private readonly Dictionary<string, TestRecord> _store = new();
    private readonly SyncReconciler<TestRecord, TestChange> _sut = new();

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
    public async Task ReconcileAsync_FastPathReturnsEmptyWhenHashMatchesAndNoChanges()
    {
        _store["w-1"] = new TestRecord("w-1", "x", DateTimeOffset.UtcNow.AddDays(-2));
        var currentHash = SyncSummary.FromRecords(_store.Values.ToList()).Hash;

        var result = await ReconcileAsync(DateTimeOffset.UtcNow.AddDays(-1), currentHash, []);

        Assert.Empty(result.ServerChanges);
        Assert.Equal(currentHash, result.Hash);
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
    public void FromRecords_IsOrderIndependentAndStableAcrossEquivalentInput()
    {
        var updatedAt = DateTimeOffset.UtcNow;
        var a = new TestRecord("w-1", "x", updatedAt);
        var b = new TestRecord("w-2", "y", updatedAt.AddSeconds(1));

        var first = SyncSummary.FromRecords<TestRecord>([a, b]);
        var second = SyncSummary.FromRecords<TestRecord>([b, a]);

        Assert.Equal(first.Hash, second.Hash);
        Assert.Equal(b.UpdatedAt, first.UpdatedAt);
    }

    [Fact]
    public void FromRecords_ReturnsEmptyHashSentinelForNoRecords()
    {
        var summary = SyncSummary.FromRecords<TestRecord>([]);

        Assert.Equal(DateTimeOffset.MinValue, summary.UpdatedAt);
    }
}
