using Kuulla.Api.Models;

namespace Kuulla.Api.Services;

public interface IPlaylistService
{
    Task<IReadOnlyList<Playlist>> GetPlaylistsAsync(string userId, CancellationToken cancellationToken);

    Task<Playlist> CreatePlaylistAsync(string userId, string name, CancellationToken cancellationToken);

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
