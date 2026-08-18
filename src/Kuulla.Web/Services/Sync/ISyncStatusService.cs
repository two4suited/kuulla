namespace Kuulla.Web.Services.Sync;

// Non-generic surface a SyncStatusIndicator binds to, so the indicator component doesn't need to
// be generic over the domain's record type — only SyncStatusService<T> (the implementation) is.
public interface ISyncStatusService
{
    bool IsSyncing { get; }

    bool HasRemoteUpdate { get; }

    // Raised whenever IsSyncing or HasRemoteUpdate changes, so a bound component knows to
    // re-render.
    event Action? StateChanged;

    // Polls the domain's sync endpoint for changes. Safe to call repeatedly (e.g. from
    // poll-on-focus) — a check already in flight is not duplicated.
    Task CheckNowAsync(CancellationToken cancellationToken = default);

    // Dismisses the "updated from another device" indicator once the user has seen it.
    Task AcknowledgeRemoteUpdateAsync(CancellationToken cancellationToken = default);
}
