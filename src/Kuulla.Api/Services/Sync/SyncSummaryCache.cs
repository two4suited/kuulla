using System.Security.Cryptography;
using System.Text;
using Kuulla.Api.Models;
using Newtonsoft.Json;
using StackExchange.Redis;

namespace Kuulla.Api.Services.Sync;

// Generic form of the sync:{domain}:{userId} -> { hash, updatedAt } cache from
// docs/sync-conventions.md (originally #83/#33, extracted in #84). One instance per domain,
// parameterized by the record shape so Compute() can hash that domain's records without the
// domain re-implementing the hash algorithm.
// `class` constraint matches SyncReconciler<TState, TChange>'s — kept consistent so a record
// type satisfies both without a mismatch surfacing only when a second domain is wired up.
public class SyncSummaryCache<T>(IConnectionMultiplexer redis, string domain)
    where T : class, ISyncableRecord
{
    // Matches EpisodeStateService's rationale: a summary is only useful while a device might
    // still hold the hash it's compared against, so it doesn't need to outlive an inactive
    // device forever.
    private static readonly TimeSpan Ttl = TimeSpan.FromDays(30);

    private string Key(string userId) => $"sync:{domain}:{userId}";

    public async Task<SyncSummary?> GetAsync(string userId, CancellationToken cancellationToken)
    {
        var db = redis.GetDatabase();
        var cached = await db.StringGetAsync(Key(userId));
        return cached.HasValue ? JsonConvert.DeserializeObject<SyncSummary>((string)cached!) : null;
    }

    public async Task SetAsync(string userId, SyncSummary summary, CancellationToken cancellationToken)
    {
        var db = redis.GetDatabase();
        await db.StringSetAsync(Key(userId), JsonConvert.SerializeObject(summary), Ttl);
    }

    // Drops a stale cached summary rather than recomputing it inline — used by the /dev/seed-*
    // endpoints (#249), which write straight to Cosmos without going through the owning
    // service's Set/RecomputeSummaryAsync call. Without this, a summary cached before seeding
    // (e.g. from an earlier /api/sync/{domain} call for the same user) would keep reporting
    // "no changes" for up to the 30-day TTL even though Cosmos now has new/updated records.
    public async Task InvalidateAsync(string userId, CancellationToken cancellationToken)
    {
        var db = redis.GetDatabase();
        await db.KeyDeleteAsync(Key(userId));
    }

    // Cache-or-recompute: used on the fast path where there's nothing to reconcile and only the
    // hash needs checking.
    public async Task<SyncSummary> GetOrComputeAsync(
        string userId,
        Func<CancellationToken, Task<IReadOnlyList<T>>> queryAll,
        CancellationToken cancellationToken)
    {
        var cached = await GetAsync(userId, cancellationToken);
        if (cached is not null)
        {
            return cached;
        }

        var summary = Compute(await queryAll(cancellationToken));
        await SetAsync(userId, summary, cancellationToken);
        return summary;
    }

    // docs/sync-conventions.md: hash = SHA-256 over the sorted set of "{recordId}:{updatedAt}"
    // pairs; updatedAt = max updatedAt across the collection (DateTimeOffset.MinValue when empty,
    // matching an always-caught-up client with nothing to sync).
    public static SyncSummary Compute(IReadOnlyList<T> records)
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
