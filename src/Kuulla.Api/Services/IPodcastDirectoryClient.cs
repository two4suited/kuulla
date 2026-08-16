using Kuulla.Api.Models;

namespace Kuulla.Api.Services;

// Searches the wider podcast catalog, not just shows we already have cached — the
// user's own library is a small subset of what's discoverable.
public interface IPodcastDirectoryClient
{
    Task<IReadOnlyList<Show>> SearchAsync(string query, CancellationToken cancellationToken);
}
