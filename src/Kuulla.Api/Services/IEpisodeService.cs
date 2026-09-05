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

    // Create-only insert of newly-fetched episodes plus the enforcement that runs off the back of
    // it (unlistened-episode-limit, dynamic-playlist auto-insert/evict). Public so the dev-only
    // /dev/simulate-new-episodes endpoint (#112) can drive the exact same path a real feed refresh
    // takes, instead of writing episodes straight into Cosmos the way /dev/seed-episodes does —
    // that bypass is fine for tests that only need episodes to exist, but the auto-ordering
    // milestone's tests need the real enforcement pipeline to actually run.
    Task CacheEpisodesAsync(string showId, IReadOnlyList<Episode> episodes, CancellationToken cancellationToken);

    Task EnforceUnlistenedLimitAsync(string userId, string showId, CancellationToken cancellationToken);

    Task EnforceAutoArchiveRuleAsync(string userId, string showId, CancellationToken cancellationToken);

    // All of a show's cached episodes, newest first — no paging, unlike GetEpisodesAsync.
    // Used where a caller needs the full ordered set to derive something from it (e.g.
    // PlaylistService computing a dynamic playlist's contents), not to page through a UI list.
    Task<IReadOnlyList<Episode>> GetAllEpisodesOrderedAsync(string showId, CancellationToken cancellationToken);

    // The publish date of the show's newest *already-cached* episode, or null if none are
    // cached. Unlike GetEpisodesAsync this never falls back to fetching the live feed — it's a
    // single-item indexed read used to seed Subscription.LatestEpisodePublishedAt on subscribe
    // (#438) without putting a feed round-trip on the request path.
    Task<DateTimeOffset?> GetNewestCachedEpisodePublishedAtAsync(string showId, CancellationToken cancellationToken);
}
