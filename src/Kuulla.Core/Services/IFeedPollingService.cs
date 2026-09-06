namespace Kuulla.Core.Services;

// Server-side counterpart to the client-driven refresh in EpisodeService.GetEpisodesAsync: that
// path only re-fetches a show's feed when some user happens to open it, so a subscriber who never
// opens the app wouldn't otherwise get a new episode cached (and, via #216, notified) until they
// did. A single method (rather than folded directly into Kuulla.FeedPoller's FeedPollingWorker) so
// the actual polling logic can be unit tested without standing up a BackgroundService's timer loop.
public interface IFeedPollingService
{
    Task PollOnceAsync(CancellationToken cancellationToken);
}
