namespace Kuulla.Web.Models;

// Web-side subset of Kuulla.Api.Models.Playlist's wire shape — deliberately drops UserId (the
// Web client only ever deals with the authenticated user's own playlists) and DeviceId
// (sync-internal metadata not consumed by any Blazor page), matching Subscription.cs's mirror.
public record Playlist(
    string Id,
    string Name,
    PlaylistType Type,
    IReadOnlyList<PlaylistItem> Items,
    DateTimeOffset CreatedAt,
    DateTimeOffset UpdatedAt,
    DynamicPlaylistConfig? DynamicConfig = null);

// Web-side mirror of Kuulla.Api.Models.PlaylistItem's wire shape.
public record PlaylistItem(
    string EpisodeId,
    string ShowId,
    DateTimeOffset AddedAt,
    string Order);

public enum PlaylistType
{
    Manual,
    Dynamic,
}

// Web-side mirror of Kuulla.Api.Models.DynamicPlaylistConfig's wire shape.
public record DynamicPlaylistConfig(
    IReadOnlyList<string> ShowIds,
    int MaxEpisodes,
    IReadOnlyList<string> PriorityList);

// Web-side mirror of Kuulla.Api.Models.PlaylistDetail's wire shape — GET /api/playlists/{id}'s
// response, items resolved with episode title/show artwork.
public record PlaylistDetail(
    string Id,
    string Name,
    PlaylistType Type,
    IReadOnlyList<PlaylistItemDetail> Items,
    DateTimeOffset CreatedAt,
    DateTimeOffset UpdatedAt,
    DynamicPlaylistConfig? DynamicConfig = null);

// Web-side mirror of Kuulla.Api.Models.PlaylistItemDetail's wire shape.
public record PlaylistItemDetail(
    string EpisodeId,
    string ShowId,
    string? Title,
    string? ArtworkUrl,
    DateTimeOffset AddedAt,
    string Order);
