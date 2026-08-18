using Newtonsoft.Json;

namespace Kuulla.Api.Models;

// Global per-user settings document. Partitioned (and keyed) by UserId so "get a user's
// settings" is a single-partition point read, and a user has exactly one settings document —
// there's nothing to disambiguate with a separate id, so Id and UserId are the same value.
// Version is a plain counter (bumped on every update) rather than relying on Cosmos ETags,
// so conflict detection works the same way whether the caller round-trips an ETag or not.
public record UserSettings(
    [property: JsonProperty("id")] string UserId,
    UnlistenedEpisodeCount UnlistenedEpisodeCount,
    int Version)
{
    public static UserSettings CreateDefault(string userId) =>
        new(userId, UnlistenedEpisodeCount.Five, Version: 1);
}

// How many unlistened episodes to surface per show (e.g. on a show's page or in a "new
// episodes" list). Unlimited is its own case rather than a sentinel numeric value so callers
// can't mistake it for a literal count.
public enum UnlistenedEpisodeCount
{
    One = 1,
    Two = 2,
    Five = 5,
    Ten = 10,
    Unlimited = -1,
}
