using Kuulla.Core.Models;

namespace Kuulla.Core.Services;

// Title/Author/ArtworkUrl are only populated by the channel-level parse in PodcastFeedClient and
// are only consumed by ShowService.GetOrCreateByFeedUrlAsync, which has to mint a Show from a
// bare feed URL (OPML import) with no iTunes record to draw metadata from. The episode-refresh
// callers ignore them.
public record PodcastFeedContent(
    string? Description,
    IReadOnlyList<Episode> Episodes,
    string? Title = null,
    string? Author = null,
    string? ArtworkUrl = null);
