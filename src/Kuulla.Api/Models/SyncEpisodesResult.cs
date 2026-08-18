namespace Kuulla.Api.Models;

public record SyncEpisodesResult(
    IReadOnlyList<EpisodeState> ServerChanges,
    DateTimeOffset SyncedAt,
    string Hash);
