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
    DateTimeOffset UpdatedAt);

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
