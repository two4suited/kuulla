namespace Kuulla.Api.Models;

// Title/ArtworkUrl are nullable because episode/show resolution is best-effort — a deleted or
// unreachable episode/show shouldn't 404 the whole playlist, just leave that item's display
// fields blank (mirrors GetNewEpisodesAsync's per-show fault isolation in SubscriptionService).
public record PlaylistItemDetail(
    string EpisodeId,
    string ShowId,
    string? Title,
    string? ArtworkUrl,
    DateTimeOffset AddedAt,
    string Order);
