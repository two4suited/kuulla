namespace Kuulla.Core.Models;

public record SyncPlaylistsResult(
    IReadOnlyList<Playlist> ServerChanges,
    DateTimeOffset SyncedAt,
    string Hash);
