using Kuulla.Api.Services.Sync;
using Newtonsoft.Json;

namespace Kuulla.Api.Models;

// Partitioned by UserId so "a user's episode states" — the sync/reconciliation access
// pattern (#33) — is a single-partition query. Id is the EpisodeId (unique within a user's
// partition), making point reads/writes idempotent per (user, episode) pair.
// UpdatedAt/DeviceId follow the sync-metadata convention in docs/sync-conventions.md — server
// stamps UpdatedAt on every write, client-supplied values are never trusted for storage.
// Implements ISyncableRecord so the generic sync-summary cache/reconciler (#84) can hash and
// reconcile episode states without episode-specific code.
public record EpisodeState(
    [property: JsonProperty("id")] string Id,
    string UserId,
    string EpisodeId,
    string ShowId,
    int PositionSeconds,
    bool Completed,
    [property: JsonProperty("updatedAt")] DateTimeOffset UpdatedAt,
    [property: JsonProperty("deviceId")] string? DeviceId = null,
    // True only when the unlistened-episode-limit enforcement job marked this episode played
    // rather than the user (#97) — lets the UI show "auto-marked played" with an undo.
    bool AutoPlayed = false) : ISyncableRecord;
