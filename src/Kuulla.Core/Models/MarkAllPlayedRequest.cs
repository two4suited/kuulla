namespace Kuulla.Core.Models;

// Body for POST /api/shows/{showId}/episode-state/mark-all-played. DeviceId follows the same
// sync-metadata convention as UpdateEpisodeStateRequest — it's stamped onto every episode-state
// row the bulk mark touches, purely for debugging/telemetry (docs/sync-conventions.md).
public record MarkAllPlayedRequest(string? DeviceId);
