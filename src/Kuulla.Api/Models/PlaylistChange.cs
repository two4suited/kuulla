namespace Kuulla.Api.Models;

// The shape of a client-pushed playlist change for POST /api/sync/playlists (mirrors
// EpisodeStateChange for /api/sync/episodes). CreatedAt is trusted from the client here — unlike
// UpdatedAt/DeviceId, it isn't part of the sync-metadata convention (docs/sync-conventions.md)
// and doesn't participate in last-write-wins conflict resolution, so there's no correctness
// reason to re-derive it server-side; it's just the client's own record of when it created the
// playlist.
public record PlaylistChange(
    string Id,
    string Name,
    PlaylistType Type,
    IReadOnlyList<PlaylistItem> Items,
    DateTimeOffset CreatedAt,
    DateTimeOffset UpdatedAt);
