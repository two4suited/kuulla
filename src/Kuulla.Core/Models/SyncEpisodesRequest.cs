namespace Kuulla.Core.Models;

public record SyncEpisodesRequest(
    string DeviceId,
    DateTimeOffset LastSyncedAt,
    string LocalHash,
    IReadOnlyList<EpisodeStateChange> Changes);
