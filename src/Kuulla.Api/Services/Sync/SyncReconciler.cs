namespace Kuulla.Api.Services.Sync;

// Generic form of the always-push/always-return-delta reconciliation routine designed in #32/#33
// for episode sync (see docs/sync-conventions.md) and extracted in #84 so other domains (e.g.
// #41 settings sync) implement a small adapter — the read/write/query delegates below — instead
// of re-deriving the merge and delta logic.
//
// TState is the domain's stored record shape (must be ISyncableRecord so the summary hash can be
// computed). TChange is the shape of an incoming client-pushed change, which may differ from
// TState (e.g. it won't carry a server-stamped updatedAt/deviceId).
public class SyncReconciler<TState, TChange>(SyncSummaryCache<TState> summaryCache)
    where TState : class, ISyncableRecord
{
    public async Task<SyncReconciliationResult<TState>> ReconcileAsync(
        string userId,
        DateTimeOffset lastSyncedAt,
        string localHash,
        IReadOnlyList<TChange> changes,
        Func<TChange, string> getChangeId,
        Func<TChange, DateTimeOffset> getChangeUpdatedAt,
        Func<TChange, TState?, TState> buildAcceptedState,
        Func<string, CancellationToken, Task<TState?>> readStoredAsync,
        Func<TState, CancellationToken, Task> upsertAsync,
        Func<CancellationToken, Task<IReadOnlyList<TState>>> queryAllAsync,
        CancellationToken cancellationToken)
    {
        // Fast path (docs/sync-conventions.md): nothing to push and the client's hash already
        // matches the server's — skip the reconciliation query entirely.
        if (changes.Count == 0)
        {
            var summary = await summaryCache.GetOrComputeAsync(userId, queryAllAsync, cancellationToken);
            if (summary.Hash == localHash)
            {
                return new SyncReconciliationResult<TState>([], DateTimeOffset.UtcNow, summary.Hash);
            }
        }

        var storedByChange = await Task.WhenAll(
            changes.Select(change => readStoredAsync(getChangeId(change), cancellationToken)));

        var accepted = new List<TState>();
        for (var i = 0; i < changes.Count; i++)
        {
            var change = changes[i];
            var stored = storedByChange[i];
            if (stored is not null && stored.UpdatedAt >= getChangeUpdatedAt(change))
            {
                // Stored record wins — client's write is discarded (its version is stale).
                continue;
            }

            accepted.Add(buildAcceptedState(change, stored));
        }

        await Task.WhenAll(accepted.Select(state => upsertAsync(state, cancellationToken)));
        var acceptedIds = accepted.Select(s => s.Id).ToHashSet();

        var allStates = await queryAllAsync(cancellationToken);

        // Delta: everything newer than the client's last sync that it doesn't already hold the
        // winning version of (records it just pushed and had accepted above).
        var serverChanges = allStates
            .Where(s => s.UpdatedAt > lastSyncedAt && !acceptedIds.Contains(s.Id))
            .ToList();

        var newSummary = SyncSummaryCache<TState>.Compute(allStates);
        await summaryCache.SetAsync(userId, newSummary, cancellationToken);

        return new SyncReconciliationResult<TState>(serverChanges, DateTimeOffset.UtcNow, newSummary.Hash);
    }
}
