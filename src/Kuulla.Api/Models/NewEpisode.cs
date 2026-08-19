namespace Kuulla.Api.Models;

// Episode paired with whether the unlistened-episode-limit job (#98) is what marked it played,
// rather than the user. Without this, an auto-played episode would just silently drop out of
// GetNewEpisodesAsync's results the moment it gained an EpisodeState — AutoPlayed is what lets
// it keep showing up there (with a distinct indicator) instead of vanishing unexplained.
public record NewEpisode(Episode Episode, bool AutoPlayed);
