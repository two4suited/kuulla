using Kuulla.Core.Models;

namespace Kuulla.Core.Services;

public interface IShowService
{
    Task<Show?> GetByIdAsync(string id, CancellationToken cancellationToken);

    // Get (or lazily create) a Show from just its RSS feed URL — the only identifier an OPML
    // entry carries. The Show.Id is derived deterministically from the normalized feed URL so
    // repeated imports of the same feed collapse to one show. Returns null when the feed can't
    // be fetched or parsed, so the importer can record a per-entry failure.
    Task<Show?> GetOrCreateByFeedUrlAsync(string feedUrl, CancellationToken cancellationToken);

    // A plain point-read for just a show's feed URL — no description enrichment / feed fetch,
    // unlike GetByIdAsync. Used by OPML import to resolve legacy Subscription rows that predate
    // Subscription.FeedUrl. Null when the show doesn't exist or has no feed URL.
    Task<string?> TryGetFeedUrlAsync(string showId, CancellationToken cancellationToken);

    Task<IReadOnlyList<Show>> SearchAsync(string query, CancellationToken cancellationToken);

    Task<IReadOnlyList<Show>> GetTrendingAsync(string? category, CancellationToken cancellationToken);
}
