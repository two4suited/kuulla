namespace Kuulla.Api.Models;

public record SyncPlaylistsRequest(
    string DeviceId,
    DateTimeOffset LastSyncedAt,
    string LocalHash,
    IReadOnlyList<PlaylistChange> Changes);
