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
    // Nullable (unlike every non-nullable field above) because this field is newer than the
    // rest of this DTO: an existing client that hasn't been updated to send it yet will omit
    // the JSON property entirely, and minimal-API request binding (System.Text.Json) populates a
    // missing non-nullable bool with false — not the client's actual, unrelated notification
    // preference. Null here means "this client doesn't know about this setting yet", so
    // SettingsService.SyncAsync falls back to the stored value instead of clobbering it.
    bool? NotificationsEnabled,
    // Nullable for two overlapping reasons: like NotificationsEnabled above, an existing client
    // that hasn't been updated to send it yet must not clobber the stored value with 0; and
    // separately, null is also this field's own steady-state meaning in UserSettings itself (the
    // user has never picked a sleep timer duration). SettingsService.SyncAsync can't tell those
    // two "null" cases apart from this DTO alone, so it falls back to the stored value either
    // way — a client can never explicitly clear a previously-picked default back to "unset" via
    // sync, only by picking a different duration.
    int? SleepTimerDefaultDurationMinutes,
    DateTimeOffset UpdatedAt);
