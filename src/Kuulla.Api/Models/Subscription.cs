using Newtonsoft.Json;

namespace Kuulla.Api.Models;

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
    DateTimeOffset SubscribedAt);
