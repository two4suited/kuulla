using Kuulla.Api.Services.Sync;
using Newtonsoft.Json;

namespace Kuulla.Api.Models;

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
    [property: JsonProperty("deviceId")] string? DeviceId = null) : ISyncableRecord;

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
