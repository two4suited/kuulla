namespace Kuulla.Api.Models;

// Cached in Redis at sync:episodes:{userId} per docs/sync-conventions.md.
public record SyncSummary(string Hash, DateTimeOffset UpdatedAt);
