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
    DynamicPlaylistConfig? DynamicConfig = null,
    // Curated emoji from PlaylistIcons.Curated, or null for "no icon" (#439).
    string? Icon = null,
    string? AccentColor = null,
    // Per-playlist "what plays when an episode finishes" override (#629); null inherits the
    // show / global setting. Edited through PUT /api/playlists/{id} alongside Name/Icon.
    PlayNextBehavior? PlayNextBehavior = null,
    // Tombstone flag (#400). A sync poll's ServerChanges can include a deleted playlist with
    // Deleted = true; PlaylistDetail.razor treats that as "removed on another device". The plain
    // GET /api/playlists list never returns tombstoned playlists.
    bool Deleted = false);

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

// The Overcast-style "Up Next" queue is a regular Manual playlist the app resolves (or creates)
// by this well-known name (see UpNext.razor) — there's no distinct backend "default playlist"
// concept. PlaylistDetail.razor keys its queue-behaviour settings section off the same name.
public static class WellKnownPlaylists
{
    public const string UpNextName = "Up Next";
}

// Web-side mirror of Kuulla.Api.Models.DynamicPlaylistConfig's wire shape. MaxEpisodes is nullable
// — null means unlimited.
public record DynamicPlaylistConfig(
    IReadOnlyList<string> ShowIds,
    int? MaxEpisodes,
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
    DynamicPlaylistConfig? DynamicConfig = null,
    string? Icon = null,
    string? AccentColor = null,
    PlayNextBehavior? PlayNextBehavior = null);

// Web-side mirror of Kuulla.Api.Models.PlaylistItemDetail's wire shape.
public record PlaylistItemDetail(
    string EpisodeId,
    string ShowId,
    string? Title,
    string? ArtworkUrl,
    DateTimeOffset AddedAt,
    string Order);
