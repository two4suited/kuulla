using Newtonsoft.Json;

namespace Kuulla.Api.Models;

// Global per-user settings document. Partitioned (and keyed) by UserId so "get a user's
// settings" is a single-partition point read, and a user has exactly one settings document —
// there's nothing to disambiguate with a separate id, so Id and UserId are the same value.
// Version is a plain counter bumped on every update, surfaced to clients so they can tell
// their local copy is stale. It is NOT yet compared against on write (updates are a plain
// read-modify-write upsert), so it doesn't prevent a lost update under concurrent writes —
// wiring it (or Cosmos's own ETag) into an optimistic-concurrency check on
// SettingsService.UpdateUnlistenedEpisodeCountAsync is follow-up work.
public record UserSettings(
    [property: JsonProperty("id")] string UserId,
    UnlistenedEpisodeCount UnlistenedEpisodeCount,
    int Version,
    // Never is the safe, non-destructive default — auto-archiving is opt-in rather than
    // surprising a user by hiding played episodes they never asked to have hidden.
    AutoArchiveRule AutoArchiveRule = AutoArchiveRule.Never)
{
    public static UserSettings CreateDefault(string userId) =>
        new(userId, UnlistenedEpisodeCount.Five, Version: 1, AutoArchiveRule.Never);

    // Discriminator so a future cross-partition/container-wide query can filter by document
    // shape instead of guessing from the id string or risking a wrong-typed deserialization
    // against ShowSettings, which shares the same "settings" container.
    [JsonProperty("type")]
    public string Type => "UserSettings";
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
