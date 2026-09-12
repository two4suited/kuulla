namespace Kuulla.Core.Services;

// A show's saved conditional-GET headers plus the newest PublishedAt already cached for it
// (#579). FeedPollingService builds one of these per show before polling so PodcastFeedClient can
// skip the fetch entirely (ETag/LastModified unchanged -> 304) or skip chapters/back-catalog work
// for episodes it already knows about (WatermarkPublishedAt).
public record FeedPollCursor(string? ETag, string? LastModified, DateTimeOffset? WatermarkPublishedAt);

// Content is null when NotModified is true (the feed hasn't changed since the cursor was taken)
// or when the feed fetched successfully but had no <channel> to parse. ETag/LastModified are the
// values to persist as the show's new cursor — echoed back unchanged on a 304 so the caller can
// always just save whatever comes back.
public record FeedPollResult(bool NotModified, PodcastFeedContent? Content, string? ETag, string? LastModified);
