namespace Kuulla.Core.Models;

// A single record in a POST /api/sync/episodes request. UpdatedAt here is the client's local
// edit timestamp — used only to arbitrate last-write-wins against the stored record; if
// accepted, the server re-stamps UpdatedAt with its own clock (docs/sync-conventions.md: never
// trust a client-supplied value for storage).
public record EpisodeStateChange(
    string EpisodeId,
    string ShowId,
    int PositionSeconds,
    bool Completed,
    DateTimeOffset UpdatedAt);
