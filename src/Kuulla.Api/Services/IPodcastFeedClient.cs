namespace Kuulla.Api.Services;

// Podcast directories (iTunes, etc.) only point at a show's RSS feed — the description
// and episode list themselves live in the feed and have to be fetched and parsed directly.
public interface IPodcastFeedClient
{
    Task<PodcastFeedContent?> FetchAsync(string feedUrl, CancellationToken cancellationToken);
}
