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
    bool AutoPlayed = false,
    // Stamped the first time Completed transitions to true (and cleared back to null when the
    // episode is marked unplayed again) so the auto-archive rule (#187) can measure elapsed
    // time since the episode was played without confusing it with UpdatedAt, which also moves
    // on unrelated position updates.
    DateTimeOffset? PlayedAt = null,
    // Set by the auto-archive enforcement job (#187) once the effective AutoArchiveRule's delay
    // has elapsed since PlayedAt. Purely a visibility flag for episode lists — it does not
    // affect downloads.
    bool Archived = false) : ISyncableRecord;
