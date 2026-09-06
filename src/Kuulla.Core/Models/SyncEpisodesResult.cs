namespace Kuulla.Core.Models;

public record SyncEpisodesResult(
    IReadOnlyList<EpisodeState> ServerChanges,
    DateTimeOffset SyncedAt,
    string Hash);
