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
