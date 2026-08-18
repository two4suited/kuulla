namespace Kuulla.Web.Services.Sync;

// Web-side mirror of the API's SyncReconciliationResult<T> (Kuulla.Api.Services.Sync, #84):
// { serverChanges, syncedAt, hash }. Any domain's sync client (episodes, and #41 settings once
// it exists) returns this shape from an empty-changes poll so SyncStatusService<T> stays generic
// across domains.
public record SyncCheckResult<TState>(
    IReadOnlyList<TState> ServerChanges,
    DateTimeOffset SyncedAt,
    string Hash);
