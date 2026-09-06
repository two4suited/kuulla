namespace Kuulla.Core.Models;

// Episode paired with whether the unlistened-episode-limit job (#98) is what marked it played,
// rather than the user. Without this, an auto-played episode would just silently drop out of
// GetNewEpisodesAsync's results the moment it gained an EpisodeState — AutoPlayed is what lets
// it keep showing up there (with a distinct indicator) instead of vanishing unexplained.
//
// ShowTitle/ShowArtworkUrl are carried alongside so the New Episodes list can identify which
// podcast each row is from without an N+1 fan-out to the shows container (#441). They're snapshotted
// from the user's Subscription, which already embeds both.
public record NewEpisode(Episode Episode, bool AutoPlayed, string ShowTitle, string? ShowArtworkUrl);
