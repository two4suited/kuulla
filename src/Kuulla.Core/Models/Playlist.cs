using Kuulla.Core.Services.Sync;
using Newtonsoft.Json;

namespace Kuulla.Core.Models;

// Partitioned by UserId, own container ("playlists") rather than reusing "settings" or
// "subscriptions" — playlists have their own lifecycle and growth pattern (embedded item lists)
// that doesn't fit either existing container's access pattern.
// UpdatedAt/DeviceId follow the sync-metadata convention in docs/sync-conventions.md — server
// stamps UpdatedAt on every write, client-supplied values are never trusted for storage.
// Implements ISyncableRecord so the generic sync-summary cache/reconciler (#84) can hash and
// reconcile playlists without playlist-specific code, once #105 wires the sync endpoint.
public record Playlist(
    [property: JsonProperty("id")] string Id,
    string UserId,
    string Name,
    PlaylistType Type,
    IReadOnlyList<PlaylistItem> Items,
    DateTimeOffset CreatedAt,
    [property: JsonProperty("updatedAt")] DateTimeOffset UpdatedAt,
    [property: JsonProperty("deviceId")] string? DeviceId = null,
    DynamicPlaylistConfig? DynamicConfig = null,
    // Curated emoji from PlaylistIcons.Curated, or null for "no icon" (client falls back to its
    // default glyph). Travels in the sync payload and reconciles last-write-wins like Name (#439).
    [property: JsonProperty("icon")] string? Icon = null,
    [property: JsonProperty("accentColor")] string? AccentColor = null,
    // Tombstone flag (#400, ISyncableRecord.Deleted). DeletePlaylistAsync flips this instead of
    // hard-deleting the Cosmos item so the deletion reaches other devices through
    // POST /api/sync/playlists; GetPlaylistsAsync/GetPlaylistDetailAsync and every mutation path
    // treat a Deleted playlist as absent. The row is hard-deleted only once it ages past the sync
    // retention window (PlaylistService.TombstoneRetention).
    [property: JsonProperty("deleted")] bool Deleted = false) : ISyncableRecord
{
    // The "Up Next" queue is a regular manual playlist the clients resolve (or create) by this
    // well-known name rather than a distinct backend concept — see UpNext.razor / UpNextView.swift.
    // Duplicated here (not shared with those clients, which are separate codebases) so the feed
    // poller's auto-add hook can find-or-create the same playlist server-side.
    public const string UpNextName = "Up Next";
}

// Embedded on Playlist rather than a separate container/doc — items are always read/written
// with their parent playlist, and doc size (a few hundred episode refs) is well within Cosmos's
// 2MB limit.
// Order is a lexicographically sortable rank string (LexoRank-style), not an integer index —
// CLAUDE.md flags rank strings for queue ordering because integer positions collide or require
// renumbering under concurrent last-write-wins sync from two devices; a rank string lets a
// single reorder/insert touch only the moved item.
// ShowId is stored alongside EpisodeId (rather than looked up later) because the episodes
// container is partitioned by ShowId (#105) — resolving an item's title/artwork needs both to do
// a cheap single-partition point read instead of an expensive cross-partition scan by episode id
// alone.
public record PlaylistItem(
    string EpisodeId,
    string ShowId,
    DateTimeOffset AddedAt,
    string Order);

// Manual playlists are user-curated ordered lists (this milestone); Dynamic playlists are
// rule-defined (Dynamic Playlist Rules milestone) — the discriminator lets both share the same
// container/model without a separate dynamic-only container. Dynamic-specific config fields land
// in a later issue.
public enum PlaylistType
{
    Manual,
    Dynamic,
}

// Present only when Playlist.Type == Dynamic. PriorityList is a plain ordered array of ShowId
// rather than a rank-string scheme like PlaylistItem.Order — it's edited wholesale by one user in
// a settings screen, not concurrently item-by-item, so reordering + last-write-wins on the whole
// array is sufficient and simpler. PriorityList drives which episodes get inserted and in what
// order when new ones arrive (Dynamic Playlist Auto-Ordering milestone); it isn't itself the item
// ordering — Items/Order above still owns that.
// MaxEpisodes is nullable — null means unlimited (all episodes from all configured shows are
// included), which is the default. When set, it caps the total item count.
public record DynamicPlaylistConfig(
    IReadOnlyList<string> ShowIds,
    int? MaxEpisodes,
    IReadOnlyList<string> PriorityList);
