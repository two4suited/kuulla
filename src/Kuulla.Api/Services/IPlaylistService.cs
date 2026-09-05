using Kuulla.Api.Models;

namespace Kuulla.Api.Services;

public interface IPlaylistService
{
    Task<IReadOnlyList<Playlist>> GetPlaylistsAsync(string userId, CancellationToken cancellationToken);

    Task<Playlist> CreatePlaylistAsync(string userId, string name, CancellationToken cancellationToken);

    Task<Playlist> CreateDynamicPlaylistAsync(
        string userId, string name, DynamicPlaylistConfig config, CancellationToken cancellationToken);

    // Updates an existing dynamic playlist's config and recomputes its Items from scratch (see
    // RecomputeDynamicPlaylistAsync). Returns null if the playlist doesn't exist or isn't Dynamic.
    Task<Playlist?> UpdateDynamicPlaylistConfigAsync(
        string userId, string id, DynamicPlaylistConfig config, CancellationToken cancellationToken);

    // Rebuilds a dynamic playlist's Items from its currently-stored DynamicConfig: queries
    // episodes across ShowIds, orders by PriorityList (show rank) then PublishedAt within a show,
    // truncates to MaxEpisodes. Factored out so the Dynamic Playlist Auto-Ordering milestone can
    // reuse it (or a per-episode incremental variant of it) instead of duplicating this logic.
    Task<Playlist?> RecomputeDynamicPlaylistAsync(string userId, string id, CancellationToken cancellationToken);

    // Resolves a playlist's items to display shape (title/artwork). For a Dynamic playlist it also
    // rebuilds Items from current play state first (same logic as RecomputeDynamicPlaylistAsync),
    // persisting only when the episode set changed — so played episodes the #112 insert hook never
    // prunes don't accumulate in the stored list and its "N episodes total" count (follow-up to
    // #433 — that fix only covered freshly-computed playlists).
    Task<PlaylistDetail?> GetPlaylistDetailAsync(string userId, string id, CancellationToken cancellationToken);

    Task<Playlist?> RenamePlaylistAsync(string userId, string id, string name, CancellationToken cancellationToken);

    Task DeletePlaylistAsync(string userId, string id, CancellationToken cancellationToken);

    Task<Playlist?> AddItemAsync(
        string userId, string id, string episodeId, string showId, CancellationToken cancellationToken);

    Task<Playlist?> RemoveItemAsync(string userId, string id, string episodeId, CancellationToken cancellationToken);

    Task<Playlist?> ReorderItemAsync(
        string userId,
        string id,
        string episodeId,
        string? beforeEpisodeId,
        string? afterEpisodeId,
        CancellationToken cancellationToken);

    Task<SyncPlaylistsResult> SyncAsync(
        string userId,
        string deviceId,
        DateTimeOffset lastSyncedAt,
        string localHash,
        IReadOnlyList<PlaylistChange> changes,
        CancellationToken cancellationToken);
}
