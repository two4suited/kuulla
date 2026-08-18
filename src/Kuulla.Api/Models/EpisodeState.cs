using Newtonsoft.Json;

namespace Kuulla.Api.Models;

// Partitioned by UserId so "a user's episode states" — the sync/reconciliation access
// pattern (#33) — is a single-partition query. Id is the EpisodeId (unique within a user's
// partition), making point reads/writes idempotent per (user, episode) pair.
// UpdatedAt/DeviceId follow the sync-metadata convention in docs/sync-conventions.md — server
// stamps UpdatedAt on every write, client-supplied values are never trusted for storage.
public record EpisodeState(
    [property: JsonProperty("id")] string Id,
    string UserId,
    string EpisodeId,
    string ShowId,
    int PositionSeconds,
    bool Completed,
    [property: JsonProperty("updatedAt")] DateTimeOffset UpdatedAt,
    [property: JsonProperty("deviceId")] string? DeviceId = null);
