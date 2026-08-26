using Kuulla.Api.Models;

namespace Kuulla.Api.Services;

// Searches the wider podcast catalog, not just shows we already have cached — the
// user's own library is a small subset of what's discoverable.
public interface IPodcastDirectoryClient
{
    Task<IReadOnlyList<Show>> SearchAsync(string query, CancellationToken cancellationToken);

    // category is an iTunes podcast genre ID (e.g. "1489" for News); null returns the overall top charts.
    Task<IReadOnlyList<Show>> GetTrendingAsync(string? category, CancellationToken cancellationToken);
}
