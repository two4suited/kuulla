namespace Kuulla.Core.Services;

// Podcast directories (iTunes, etc.) only point at a show's RSS feed — the description
// and episode list themselves live in the feed and have to be fetched and parsed directly.
public interface IPodcastFeedClient
{
    Task<PodcastFeedContent?> FetchAsync(string feedUrl, CancellationToken cancellationToken);

    // Conditional-GET poll for a subscribed show's periodic sweep (#579): sends the show's saved
    // ETag/Last-Modified so an unchanged feed short-circuits to a 304 with no parse, and — when
    // the feed did change — stops processing (and, crucially, stops fetching podcast:chapters
    // for) any <item> at or before cursor.WatermarkPublishedAt, since feeds are date-ordered and
    // everything from there on is already cached. Not used by the client-driven first-load paths
    // (GetEpisodesAsync/GetEpisodeAsync/ShowService), which always want the full feed.
    Task<FeedPollResult> PollAsync(string feedUrl, FeedPollCursor cursor, CancellationToken cancellationToken);
}
