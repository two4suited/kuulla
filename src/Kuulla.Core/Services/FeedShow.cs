using Kuulla.Core.Models;

namespace Kuulla.Core.Services;

// What ShowService.GetOrCreateByFeedUrlAsync hands back: the Show plus the newest episode
// publish date seen in the feed it fetched, so the OPML import path can seed
// Subscription.LatestEpisodePublishedAt for the "Latest episode" sort (#438, #501) without a
// second feed fetch or caching the whole back catalogue. LatestEpisodePublishedAt is null when
// the show was already known (point-read hit, no feed fetched) or the feed carried no dated
// episodes.
public record FeedShow(Show Show, DateTimeOffset? LatestEpisodePublishedAt);
