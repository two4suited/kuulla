using Kuulla.Api.Services.Sync;
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
// UpdatedAt/DeviceId follow the sync-metadata convention in docs/sync-conventions.md — server
// stamps UpdatedAt on every write, client-supplied values are never trusted for storage.
// Implements ISyncableRecord (via explicit Id => UserId, since the id column is already named
// UserId here) so the generic sync-summary cache/reconciler (#84) can hash and reconcile
// settings without settings-specific code.
public record UserSettings(
    [property: JsonProperty("id")] string UserId,
    UnlistenedEpisodeCount UnlistenedEpisodeCount,
    int Version,
    // Never is the safe, non-destructive default — auto-archiving is opt-in rather than
    // surprising a user by hiding played episodes they never asked to have hidden.
    AutoArchiveRule AutoArchiveRule = AutoArchiveRule.Never,
    // 0 = off for both, so auto-skip is opt-in and playback is unmodified until a user sets a
    // non-zero value, matching AutoArchiveRule's opt-in-by-default convention above.
    int AutoSkipIntroSeconds = 0,
    int AutoSkipOutroSeconds = 0,
    // 1.0 = normal speed, so playback is unmodified until a user picks a non-default speed.
    float PlaybackSpeed = 1.0f,
    // Never is the safe, non-destructive default — see AutoDeleteRule's own doc comment.
    AutoDeleteRule AutoDeleteRule = AutoDeleteRule.Never,
    // Only meaningful when AutoDeleteRule == AfterDays; 7 is a reasonable default grace window,
    // matching the scale of AutoArchiveRule's day-count presets.
    int AutoDeleteAfterDays = 7,
    // False is the safe default — auto-downloading is a bandwidth/storage commitment a user
    // should opt into, not one made on their behalf the first time they add a show, matching
    // AutoArchiveRule.Never/PlaybackSpeed: 1.0f's "unmodified until the user opts in" convention.
    bool AutoDownloadNewEpisodes = false,
    // False is the safe default — silence trimming and volume boost audibly alter playback, so a
    // user should opt in rather than have it applied the first time they open the app, matching
    // AutoDownloadNewEpisodes' "opt-in, not on-by-default" convention above.
    bool SmartSpeed = false,
    [property: JsonProperty("updatedAt")] DateTimeOffset UpdatedAt = default,
    [property: JsonProperty("deviceId")] string? DeviceId = null) : ISyncableRecord
{
    string ISyncableRecord.Id => UserId;

    public static UserSettings CreateDefault(string userId) =>
        new(userId, UnlistenedEpisodeCount.Five, Version: 1, AutoArchiveRule.Never, AutoSkipIntroSeconds: 0, AutoSkipOutroSeconds: 0,
            PlaybackSpeed: 1.0f, AutoDeleteRule: AutoDeleteRule.Never, AutoDeleteAfterDays: 7, AutoDownloadNewEpisodes: false,
            SmartSpeed: false, UpdatedAt: DateTimeOffset.UtcNow);

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
