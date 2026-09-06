namespace Kuulla.Core.Models;

// Body for the dev-only /dev/simulate-new-episodes endpoint (#112) — ShowId is separate from the
// Episode list (rather than trusting each Episode's own ShowId) because EpisodeService.
// CacheEpisodesAsync itself takes showId as a distinct parameter and stamps it onto every episode.
public record SimulateNewEpisodesRequest(string ShowId, List<Episode> Episodes);
