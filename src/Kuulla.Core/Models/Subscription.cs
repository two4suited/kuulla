using Newtonsoft.Json;

namespace Kuulla.Core.Models;

// Partitioned by UserId so "list a user's subscriptions" — the primary access pattern — is a
// single-partition query. Id is the ShowId (unique within a user's partition), which also makes
// subscribe/unsubscribe idempotent point operations (ReadItemAsync/DeleteItemAsync by id).
//
// Show title/author/artwork are embedded rather than referenced: the subscriptions list only
// needs enough to render a grid, and embedding avoids an N+1 fan-out to the shows container on
// every read. This snapshot can drift from the live Show if it's edited later, but show metadata
// changes rarely enough that the tradeoff favors read speed (CLAUDE.md: "sync must be fast").
public record Subscription(
    [property: JsonProperty("id")] string Id,
    string UserId,
    string ShowId,
    string ShowTitle,
    string ShowAuthor,
    string? ShowArtworkUrl,
    DateTimeOffset SubscribedAt,
    // The publish date of this show's most recent episode, for the "Latest episode" sort mode
    // (#438). Stamped on subscribe and kept fresh by EpisodeService.CacheEpisodesAsync whenever
    // feed polling discovers newer episodes. Null when unknown (a row that predates this field);
    // callers sort a null as oldest, and the next feed poll backfills it.
    DateTimeOffset? LatestEpisodePublishedAt = null,
    // The show's RSS feed URL, snapshotted on subscribe. Lets OPML import (#421) dedup against
    // "feeds I'm already subscribed to" and OPML export (#426) emit the feed URL without an
    // N-way point-read back to the shows container. Null on rows that predate this field;
    // callers that need it fall back to reading the show.
    string? FeedUrl = null);
