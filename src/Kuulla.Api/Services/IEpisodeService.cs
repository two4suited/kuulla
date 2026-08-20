using Kuulla.Api.Models;

namespace Kuulla.Api.Services;

public interface IEpisodeService
{
    Task<EpisodePage> GetEpisodesAsync(
        string showId,
        string? continuationToken,
        int pageSize,
        CancellationToken cancellationToken);

    Task<Episode?> GetEpisodeAsync(string showId, string episodeId, CancellationToken cancellationToken);

    Task EnforceUnlistenedLimitAsync(string userId, string showId, CancellationToken cancellationToken);

    // All of a show's cached episodes, newest first — no paging, unlike GetEpisodesAsync.
    // Used where a caller needs the full ordered set to derive something from it (e.g.
    // PlaylistService computing a dynamic playlist's contents), not to page through a UI list.
    Task<IReadOnlyList<Episode>> GetAllEpisodesOrderedAsync(string showId, CancellationToken cancellationToken);
}
