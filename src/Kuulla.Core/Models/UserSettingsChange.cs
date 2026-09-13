namespace Kuulla.Core.Models;

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
    // Nullable, same rationale as NotificationsEnabled below — a client that predates #679 omits
    // the JSON property, and null means "this client doesn't know about this setting yet", so
    // SettingsService.SyncAsync falls back to the stored value instead of clobbering it.
    bool? VoiceBoost,
    // Nullable, same rationale as VoiceBoost above — a client that predates #680 omits the JSON
    // property, and null means "this client doesn't know about this setting yet", so
    // SettingsService.SyncAsync falls back to the stored value instead of clobbering it.
    bool? TrimSilence,
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
    // Nullable for the same reason as NotificationsEnabled above: a client that predates this
    // field omits the JSON property, and STJ would bind a missing non-nullable enum to its zero
    // value (Title) — silently resetting the user's real sort choice. Null means "this client
    // doesn't know about this setting yet", so SettingsService.SyncAsync keeps the stored value.
    SubscriptionSortOrder? SubscriptionSortOrder,
    // Nullable, same rationale as SubscriptionSortOrder above. SettingsService.SyncAsync treats
    // null AND empty here as "keep whatever's stored" — it only accepts a non-empty list — so a
    // device that has no local arrangement can't wipe one saved from another device.
    IReadOnlyList<string>? SubscriptionManualOrder,
    // Nullable, same rationale as SubscriptionSortOrder above: a client that predates this field
    // omits the JSON property, and minimal-API binding would populate a missing non-nullable
    // bool with false — silently turning the setting off. Null means "this client doesn't know
    // about this setting yet", so SettingsService.SyncAsync keeps the stored value.
    bool? HideCaughtUpShows,
    // Nullable, same rationale as HideCaughtUpShows above — a client that predates #440 omits the
    // property, and null means "keep whatever's stored".
    bool? AutoAddNewEpisodesToUpNext,
    // Nullable for the same reason. Null means "keep whatever's stored" rather than resetting to
    // Bottom.
    UpNextInsertPosition? UpNextInsertPosition,
    // Nullable, same rationale as SubscriptionManualOrder above — a client that predates #568
    // omits these, and SettingsService.SyncAsync treats null AND empty as "keep whatever's
    // stored" (it only accepts a non-empty list here), so a device with no opinion can't wipe
    // another device's configured swipe actions.
    IReadOnlyList<EpisodeSwipeAction>? LeadingSwipeActions,
    IReadOnlyList<EpisodeSwipeAction>? TrailingSwipeActions,
    // Nullable, same rationale as UpNextInsertPosition above — a client that predates #629 omits
    // the property, and null means "keep whatever's stored" rather than resetting to NextInList.
    PlayNextBehavior? PlayNextBehavior,
    DateTimeOffset UpdatedAt);
