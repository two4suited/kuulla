using Kuulla.Web.Services.Sync;

namespace Kuulla.Web.Tests.Services.Sync;

public class SyncStatusServiceTests
{
    private record TestState(string Id, string Value);

    [Fact]
    public async Task CheckNowAsync_AppliesServerChangesAndSetsHasRemoteUpdate_WhenHashChangesWithChanges()
    {
        var applied = new List<TestState>();
        var change = new TestState("w-1", "server-value");
        var sut = new SyncStatusService<TestState>(
            poll: (_, _, _) => Task.FromResult(new SyncCheckResult<TestState>([change], DateTimeOffset.UtcNow, "new-hash")),
            applyServerChanges: applied.AddRange,
            initialLocalHash: "old-hash",
            initialLastSyncedAt: DateTimeOffset.UtcNow.AddHours(-1));

        await sut.CheckNowAsync();

        Assert.Single(applied);
        Assert.True(sut.HasRemoteUpdate);
        Assert.False(sut.IsSyncing);
    }

    [Fact]
    public async Task CheckNowAsync_DoesNotFlagRemoteUpdate_WhenHashUnchanged()
    {
        var sut = new SyncStatusService<TestState>(
            poll: (localHash, _, _) => Task.FromResult(new SyncCheckResult<TestState>([], DateTimeOffset.UtcNow, localHash)),
            applyServerChanges: _ => Assert.Fail("should not apply changes when nothing changed"),
            initialLocalHash: "same-hash",
            initialLastSyncedAt: DateTimeOffset.UtcNow.AddHours(-1));

        await sut.CheckNowAsync();

        Assert.False(sut.HasRemoteUpdate);
    }

    [Fact]
    public async Task CheckNowAsync_DoesNotFlagRemoteUpdate_WhenHashChangesButNoServerChanges()
    {
        // Hash can differ from a local-only recompute race; only a non-empty ServerChanges list
        // should surface the indicator.
        var sut = new SyncStatusService<TestState>(
            poll: (_, _, _) => Task.FromResult(new SyncCheckResult<TestState>([], DateTimeOffset.UtcNow, "new-hash")),
            applyServerChanges: _ => Assert.Fail("should not apply an empty change set"),
            initialLocalHash: "old-hash",
            initialLastSyncedAt: DateTimeOffset.UtcNow.AddHours(-1));

        await sut.CheckNowAsync();

        Assert.False(sut.HasRemoteUpdate);
    }

    [Fact]
    public async Task CheckNowAsync_SkipsOverlappingCallWhileOneIsInFlight()
    {
        var pollCount = 0;
        var gate = new TaskCompletionSource();
        var sut = new SyncStatusService<TestState>(
            poll: async (_, _, ct) =>
            {
                Interlocked.Increment(ref pollCount);
                await gate.Task;
                return new SyncCheckResult<TestState>([], DateTimeOffset.UtcNow, "hash");
            },
            applyServerChanges: _ => { },
            initialLocalHash: "hash",
            initialLastSyncedAt: DateTimeOffset.UtcNow);

        var first = sut.CheckNowAsync();
        var second = sut.CheckNowAsync();
        gate.SetResult();
        await Task.WhenAll(first, second);

        Assert.Equal(1, pollCount);
    }

    [Fact]
    public async Task AcknowledgeRemoteUpdateAsync_ClearsFlagAndRaisesStateChanged()
    {
        var sut = new SyncStatusService<TestState>(
            poll: (_, _, _) => Task.FromResult(new SyncCheckResult<TestState>([new TestState("w-1", "x")], DateTimeOffset.UtcNow, "new-hash")),
            applyServerChanges: _ => { },
            initialLocalHash: "old-hash",
            initialLastSyncedAt: DateTimeOffset.UtcNow);
        await sut.CheckNowAsync();
        Assert.True(sut.HasRemoteUpdate);

        var raised = false;
        sut.StateChanged += () => raised = true;
        await sut.AcknowledgeRemoteUpdateAsync();

        Assert.False(sut.HasRemoteUpdate);
        Assert.True(raised);
    }

    [Fact]
    public async Task SyncOwnWriteAsync_UpdatesLocalStateWithoutFlaggingRemoteUpdate()
    {
        var sut = new SyncStatusService<TestState>(
            poll: (localHash, _, _) => Task.FromResult(new SyncCheckResult<TestState>([], DateTimeOffset.UtcNow, "hash-after-write")),
            applyServerChanges: _ => Assert.Fail("should not apply changes for the caller's own write"),
            initialLocalHash: "old-hash",
            initialLastSyncedAt: DateTimeOffset.UtcNow.AddHours(-1));

        await sut.SyncOwnWriteAsync();

        Assert.False(sut.HasRemoteUpdate);

        // A subsequent poll compares against the hash SyncOwnWriteAsync just recorded, not the
        // stale initial one, so it shouldn't see a change either.
        await sut.CheckNowAsync();
        Assert.False(sut.HasRemoteUpdate);
    }

    [Fact]
    public async Task SyncLocalState_PreventsNextCheckFromTreatingOwnPushAsRemoteUpdate()
    {
        var sut = new SyncStatusService<TestState>(
            poll: (localHash, _, _) => Task.FromResult(new SyncCheckResult<TestState>([], DateTimeOffset.UtcNow, localHash)),
            applyServerChanges: _ => Assert.Fail("should not apply changes after local state was synced"),
            initialLocalHash: "old-hash",
            initialLastSyncedAt: DateTimeOffset.UtcNow.AddHours(-1));

        sut.SyncLocalState("hash-after-local-push", DateTimeOffset.UtcNow);
        await sut.CheckNowAsync();

        Assert.False(sut.HasRemoteUpdate);
    }
}
