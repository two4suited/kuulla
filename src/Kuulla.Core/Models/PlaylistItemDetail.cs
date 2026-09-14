namespace Kuulla.Core.Models;

// Title/ArtworkUrl are nullable because episode/show resolution is best-effort — a deleted or
// unreachable episode/show shouldn't 404 the whole playlist, just leave that item's display
// fields blank (mirrors GetNewEpisodesAsync's per-show fault isolation in SubscriptionService).
public record PlaylistItemDetail(
    string EpisodeId,
    string ShowId,
    string? Title,
    string? ArtworkUrl,
    DateTimeOffset AddedAt,
    string Order,
    // Nullable for the same reason as Episode.Duration — not every RSS feed supplies one, and
    // this rides along unchanged from there (#724's queue-remaining-time estimate treats a
    // missing duration as "unknown", not zero).
    TimeSpan? Duration = null);
