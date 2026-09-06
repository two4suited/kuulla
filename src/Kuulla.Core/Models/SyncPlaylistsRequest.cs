namespace Kuulla.Core.Models;

public record SyncPlaylistsRequest(
    string DeviceId,
    DateTimeOffset LastSyncedAt,
    string LocalHash,
    IReadOnlyList<PlaylistChange> Changes);
