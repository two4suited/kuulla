using Newtonsoft.Json;

namespace Kuulla.Core.Models;

public record Show(
    [property: JsonProperty("id")] string Id,
    string Title,
    string Author,
    string FeedUrl,
    string? ArtworkUrl,
    string? Description,
    IReadOnlyList<string> Categories,
    // Conditional-GET cursor from the show's last feed poll (#579) — sent back as
    // If-None-Match/If-Modified-Since on the next sweep so an unchanged feed costs one 304
    // round trip instead of a full fetch + parse. Null until FeedPollingService has polled this
    // show at least once (or the feed's response never carried these headers).
    string? FeedEtag = null,
    string? FeedLastModified = null);
