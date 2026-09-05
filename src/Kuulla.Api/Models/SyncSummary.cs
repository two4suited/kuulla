using System.Security.Cryptography;
using System.Text;
using Kuulla.Api.Services.Sync;

namespace Kuulla.Api.Models;

// Per-user collection summary from docs/sync-conventions.md — a content hash plus the max
// updatedAt across the user's records in a domain. Recomputed from Cosmos on demand by
// SyncReconciler rather than stored anywhere.
public record SyncSummary(string Hash, DateTimeOffset UpdatedAt)
{
    // docs/sync-conventions.md: hash = SHA-256 over the sorted set of "{recordId}:{updatedAt}"
    // pairs; updatedAt = max updatedAt across the collection (DateTimeOffset.MinValue when empty,
    // matching an always-caught-up client with nothing to sync).
    public static SyncSummary FromRecords<T>(IReadOnlyList<T> records) where T : ISyncableRecord
    {
        var pairs = records
            .Select(r => $"{r.Id}:{r.UpdatedAt:O}")
            .OrderBy(pair => pair, StringComparer.Ordinal)
            .ToArray();

        var joined = string.Join("\n", pairs);
        var hashBytes = SHA256.HashData(Encoding.UTF8.GetBytes(joined));
        var hash = Convert.ToHexString(hashBytes).ToLowerInvariant();

        var maxUpdatedAt = records.Count > 0 ? records.Max(r => r.UpdatedAt) : DateTimeOffset.MinValue;
        return new SyncSummary(hash, maxUpdatedAt);
    }
}
