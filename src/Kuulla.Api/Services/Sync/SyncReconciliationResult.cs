namespace Kuulla.Api.Services.Sync;

public record SyncReconciliationResult<T>(
    IReadOnlyList<T> ServerChanges,
    DateTimeOffset SyncedAt,
    string Hash);
