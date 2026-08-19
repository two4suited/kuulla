namespace Kuulla.Web.Models;

// Web-side mirror of Kuulla.Api.Models.Playlist's wire shape.
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
    DateTimeOffset AddedAt,
    string Order);

public enum PlaylistType
{
    Manual,
    Dynamic,
}
