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
}
