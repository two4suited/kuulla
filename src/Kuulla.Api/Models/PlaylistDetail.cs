namespace Kuulla.Api.Models;

// GET /api/playlists/{id}'s response shape — Items resolved against the episodes/shows
// containers for title/artwork, unlike the bare Playlist record other endpoints return.
public record PlaylistDetail(
    string Id,
    string Name,
    PlaylistType Type,
    IReadOnlyList<PlaylistItemDetail> Items,
    DateTimeOffset CreatedAt,
    DateTimeOffset UpdatedAt,
    DynamicPlaylistConfig? DynamicConfig = null);
