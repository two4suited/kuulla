using Kuulla.Core.Services.Sync;
using Newtonsoft.Json;

namespace Kuulla.Core.Models;

// Per-show override of a user's global UserSettings. Stored in the same "settings" container
// (partitioned by /id, so each document is its own partition — a point read), with a composite
// id so a user's per-show override for a given show has a single, directly-addressable document
// distinct from their UserSettings document (which is keyed by UserId alone).
// UnlistenedEpisodeCount is nullable: null means "no override — inherit the user's global
// setting", so clearing an override is a real, representable state rather than deleting the
// document.
// UpdatedAt/DeviceId follow the sync-metadata convention in docs/sync-conventions.md; implements
// ISyncableRecord so it can participate in the generic sync-summary cache/reconciler (#84).
public record ShowSettings(
    [property: JsonProperty("id")] string Id,
    string UserId,
    string ShowId,
    UnlistenedEpisodeCount? UnlistenedEpisodeCount,
    int Version,
    // Null means "no override — inherit the user's global AutoArchiveRule", same convention as
    // UnlistenedEpisodeCount above.
    AutoArchiveRule? AutoArchiveRule = null,
    // Null means "no override — inherit the user's global AutoSkipIntroSeconds/AutoSkipOutroSeconds".
    // Intro/outro lengths vary a lot per show, so per-show override matters more here than for
    // most settings.
    int? AutoSkipIntroSeconds = null,
    int? AutoSkipOutroSeconds = null,
    // Null means "no override — inherit the user's global PlaybackSpeed".
    float? PlaybackSpeed = null,
    // Null means "no override — inherit the user's global AutoDownloadNewEpisodes".
    bool? AutoDownloadNewEpisodes = null,
    // Null means "no override — inherit the user's global AutoDeleteRule". docs/downloads-storage-settings.md
    // originally decided against a per-show delete policy; #445 reversed that — users want per-podcast
    // control over how long downloads are kept, not just whether they're auto-downloaded.
    AutoDeleteRule? AutoDeleteRule = null,
    // Null means "no override — inherit the user's global AutoDeleteAfterDays". Only meaningful when
    // the effective rule (override-or-global) is AfterDays.
    int? AutoDeleteAfterDays = null,
    // Null means "no override — inherit the user's global SmartSpeed".
    bool? SmartSpeed = null,
    // Null means "no override — inherit the user's global AutoAddNewEpisodesToUpNext".
    bool? AutoAddNewEpisodesToUpNext = null,
    // Null means "no override — inherit the user's global UpNextInsertPosition". Only meaningful
    // when the effective auto-add (override-or-global) is on.
    UpNextInsertPosition? UpNextInsertPosition = null,
    // Null means "no override — inherit the user's global NotificationsEnabled".
    bool? NotificationsEnabled = null,
    [property: JsonProperty("updatedAt")] DateTimeOffset UpdatedAt = default,
    [property: JsonProperty("deviceId")] string? DeviceId = null) : ISyncableRecord
{
    // "show:" prefixed and with each part percent-escaped (which encodes ':' too), so a ShowSettings
    // id can never collide with a UserSettings id (a raw, unprefixed UserId) or with a different
    // (userId, showId) pair whose raw values happen to contain ':'.
    public static string BuildId(string userId, string showId) =>
        $"show:{Uri.EscapeDataString(userId)}:{Uri.EscapeDataString(showId)}";

    public static ShowSettings CreateDefault(string userId, string showId) =>
        new(BuildId(userId, showId), userId, showId, UnlistenedEpisodeCount: null, Version: 1,
            AutoArchiveRule: null, AutoSkipIntroSeconds: null, AutoSkipOutroSeconds: null, PlaybackSpeed: null,
            AutoDownloadNewEpisodes: null, AutoDeleteRule: null, AutoDeleteAfterDays: null, SmartSpeed: null,
            AutoAddNewEpisodesToUpNext: null, UpNextInsertPosition: null, NotificationsEnabled: null,
            UpdatedAt: DateTimeOffset.UtcNow);

    // Discriminator so a future cross-partition/container-wide query can filter by document
    // shape instead of guessing from the id string or risking a wrong-typed deserialization.
    [JsonProperty("type")]
    public string Type => "ShowSettings";
}
