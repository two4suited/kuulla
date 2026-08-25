namespace Kuulla.Api.Models;

// A pushed change in a POST /api/sync/settings request. UpdatedAt here is the client's local
// edit timestamp — used only to arbitrate last-write-wins against the stored record; if
// accepted, the server re-stamps UpdatedAt with its own clock (docs/sync-conventions.md: never
// trust a client-supplied value for storage). Carries every UserSettings field a client can
// edit, since a device only ever has one UserSettings record to push at a time.
public record UserSettingsChange(
    UnlistenedEpisodeCount UnlistenedEpisodeCount,
    AutoArchiveRule AutoArchiveRule,
    int AutoSkipIntroSeconds,
    int AutoSkipOutroSeconds,
    float PlaybackSpeed,
    AutoDeleteRule AutoDeleteRule,
    int AutoDeleteAfterDays,
    bool AutoDownloadNewEpisodes,
    bool SmartSpeed,
    bool NotificationsEnabled,
    DateTimeOffset UpdatedAt);
