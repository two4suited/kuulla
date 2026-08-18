namespace Kuulla.Web.Services.Sync;

// Generic "did something change elsewhere, show an indicator, reconcile" service (#86), built
// against the reconciliation contract #84 extracted on the API side. A domain wires this up by
// supplying:
//   - poll: calls its own sync endpoint with an empty change set (e.g. POST /api/sync/episodes
//     with changes: []) and returns the resulting SyncCheckResult<TState>.
//   - applyServerChanges: merges returned server records into the domain's local view-model
//     state (optimistic local update + server reconciliation on conflict, last-write-wins per
//     docs/sync-conventions.md).
//
// #34 (episode sync UI) and #42 (settings sync UI) each construct one of these instead of
// hand-rolling their own focus polling and conflict banners.
public class SyncStatusService<TState>(
    Func<string, DateTimeOffset, CancellationToken, Task<SyncCheckResult<TState>>> poll,
    Action<IReadOnlyList<TState>> applyServerChanges,
    string initialLocalHash,
    DateTimeOffset initialLastSyncedAt) : ISyncStatusService
{
    private readonly SemaphoreSlim _gate = new(1, 1);

    private string _localHash = initialLocalHash;
    private DateTimeOffset _lastSyncedAt = initialLastSyncedAt;

    public bool IsSyncing { get; private set; }

    public bool HasRemoteUpdate { get; private set; }

    public event Action? StateChanged;

    public async Task CheckNowAsync(CancellationToken cancellationToken = default)
    {
        // Poll-on-focus can fire faster than a check completes (rapid tab switching); a check
        // already in flight makes a second one redundant rather than useful.
        if (!await _gate.WaitAsync(0, cancellationToken))
        {
            return;
        }

        IsSyncing = true;
        StateChanged?.Invoke();
        try
        {
            var result = await poll(_localHash, _lastSyncedAt, cancellationToken);
            _lastSyncedAt = result.SyncedAt;

            if (result.Hash != _localHash)
            {
                _localHash = result.Hash;
                if (result.ServerChanges.Count > 0)
                {
                    applyServerChanges(result.ServerChanges);
                    HasRemoteUpdate = true;
                }
            }
        }
        finally
        {
            IsSyncing = false;
            _gate.Release();
            StateChanged?.Invoke();
        }
    }

    // Called by the domain adapter after it pushes a local change of its own (not through this
    // service), so the next poll compares against the post-push hash instead of reporting the
    // user's own write back as a remote update.
    public void SyncLocalState(string hash, DateTimeOffset syncedAt)
    {
        _localHash = hash;
        _lastSyncedAt = syncedAt;
    }

    public Task AcknowledgeRemoteUpdateAsync(CancellationToken cancellationToken = default)
    {
        HasRemoteUpdate = false;
        StateChanged?.Invoke();
        return Task.CompletedTask;
    }
}
