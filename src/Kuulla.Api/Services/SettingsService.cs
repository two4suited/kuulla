using System.Net;
using Microsoft.Azure.Cosmos;
using Microsoft.Extensions.DependencyInjection;
using Kuulla.Api.Models;
using Kuulla.Api.Services.Sync;

namespace Kuulla.Api.Services;

public class SettingsService(
    [FromKeyedServices("settings")] Container settingsContainer) : ISettingsService
{
    private readonly SyncReconciler<UserSettings, UserSettingsChange> _reconciler = new();

    public async Task<UserSettings> GetSettingsAsync(string userId, CancellationToken cancellationToken)
    {
        var stored = await ReadStoredSettingsAsync(userId, cancellationToken);
        return stored ?? UserSettings.CreateDefault(userId);
    }

    private async Task<UserSettings?> ReadStoredSettingsAsync(string userId, CancellationToken cancellationToken)
    {
        try
        {
            var response = await settingsContainer.ReadItemAsync<UserSettings>(
                userId, new PartitionKey(userId), cancellationToken: cancellationToken);
            return response.Resource;
        }
        catch (CosmosException ex) when (ex.StatusCode == HttpStatusCode.NotFound)
        {
            // No document yet — hand back null rather than writing it, so reading settings
            // never has a side effect. The first Update*Async call is what actually creates it.
            return null;
        }
    }

    private async Task<IReadOnlyList<UserSettings>> QueryAllSettingsAsync(string userId, CancellationToken cancellationToken)
    {
        var stored = await ReadStoredSettingsAsync(userId, cancellationToken);
        return stored is { } settings ? [settings] : [];
    }

    private async Task<(UserSettings Settings, string? ETag)> ReadCurrentSettingsWithETagAsync(
        string userId, CancellationToken cancellationToken)
    {
        try
        {
            var response = await settingsContainer.ReadItemAsync<UserSettings>(
                userId, new PartitionKey(userId), cancellationToken: cancellationToken);
            return (response.Resource, response.ETag);
        }
        catch (CosmosException ex) when (ex.StatusCode == HttpStatusCode.NotFound)
        {
            // No document yet. A null ETag signals "create" to UpdateSettingsWithRetryAsync
            // below, which uses CreateItemAsync (fails on a concurrent create, unlike an
            // unconditional upsert) rather than treating this as nothing-to-race-against.
            return (UserSettings.CreateDefault(userId), null);
        }
    }

    private const int MaxUpdateAttempts = 5;

    // Optimistic-concurrency retry shared by every global settings Update*Async method: re-reads
    // the single per-user settings document (and its ETag) before every attempt and writes
    // conditionally, retrying on a lost race instead of blindly overwriting. Without this, two
    // concurrent PUTs touching different fields (e.g. smart-speed from one device and
    // auto-download from another) could each read the same stale document and have the second
    // write silently discard the first's field change. This covers both an
    // existing document (IfMatchEtag) and the very first write for a user (CreateItemAsync,
    // which fails on a concurrent create the same way IfMatchEtag fails on a concurrent update)
    // — an unconditional upsert on a null ETag would leave that creation race unprotected.
    private async Task<UserSettings> UpdateSettingsWithRetryAsync(
        string userId, Func<UserSettings, UserSettings> applyChange, CancellationToken cancellationToken)
    {
        for (var attempt = 0; attempt < MaxUpdateAttempts; attempt++)
        {
            var (current, etag) = await ReadCurrentSettingsWithETagAsync(userId, cancellationToken);
            // DeviceId is cleared explicitly rather than left as `current`'s (a `with` expression
            // otherwise preserves every untouched property) — these field-specific endpoints don't
            // take a deviceId from the caller, so leaving a stale value here would misattribute this
            // write to whichever device happened to make the last sync push.
            var updated = applyChange(current) with
            {
                Version = current.Version + 1,
                UpdatedAt = DateTimeOffset.UtcNow,
                DeviceId = null,
            };

            try
            {
                var response = etag is null
                    ? await settingsContainer.CreateItemAsync(updated, new PartitionKey(userId), cancellationToken: cancellationToken)
                    : await settingsContainer.UpsertItemAsync(
                        updated, new PartitionKey(userId), new ItemRequestOptions { IfMatchEtag = etag }, cancellationToken);
                return response.Resource;
            }
            catch (CosmosException ex) when (ex.StatusCode is HttpStatusCode.PreconditionFailed or HttpStatusCode.Conflict)
            {
                // Lost the race to a concurrent writer — loop around and retry against whatever
                // it just wrote (PreconditionFailed: someone updated the existing document;
                // Conflict: someone created it first, out from under our CreateItemAsync).
            }
        }

        // Exhausted every attempt still losing the optimistic-concurrency race — surface this
        // rather than silently dropping the update, which would undermine the whole point of the
        // ETag/retry loop above.
        throw new InvalidOperationException(
            $"Failed to update settings for user '{userId}' after {MaxUpdateAttempts} attempts due to concurrent writes.");
    }

    public async Task<SyncSettingsResult> SyncAsync(
        string userId,
        string deviceId,
        DateTimeOffset lastSyncedAt,
        string localHash,
        IReadOnlyList<UserSettingsChange> changes,
        CancellationToken cancellationToken)
    {
        var result = await _reconciler.ReconcileAsync(
            userId,
            lastSyncedAt,
            localHash,
            changes,
            getChangeId: _ => userId,
            getChangeUpdatedAt: change => change.UpdatedAt,
            buildAcceptedState: (change, stored) => new UserSettings(
                userId,
                change.UnlistenedEpisodeCount,
                Version: (stored?.Version ?? 0) + 1,
                change.AutoArchiveRule,
                change.AutoSkipIntroSeconds,
                change.AutoSkipOutroSeconds,
                change.PlaybackSpeed,
                change.AutoDeleteRule,
                change.AutoDeleteAfterDays,
                change.AutoDownloadNewEpisodes,
                change.SmartSpeed,
                // Null means the pushing client doesn't send this field yet (see
                // UserSettingsChange.NotificationsEnabled) — fall back to whatever's already
                // stored (or the true default for a brand-new document) instead of clobbering an
                // existing preference the client never actually touched.
                change.NotificationsEnabled ?? stored?.NotificationsEnabled ?? true,
                // See UserSettingsChange.SleepTimerDefaultDurationMinutes — null from the client
                // always means "keep whatever's stored", never "clear it to unset".
                change.SleepTimerDefaultDurationMinutes ?? stored?.SleepTimerDefaultDurationMinutes,
                // Null means the pushing client doesn't send this field yet (see
                // UserSettingsChange.SubscriptionSortOrder) — keep the stored choice rather than
                // resetting it to Title.
                change.SubscriptionSortOrder ?? stored?.SubscriptionSortOrder ?? SubscriptionSortOrder.Title,
                // Keep the stored arrangement unless the change carries a non-empty one. A null
                // (older client) or empty list is treated as "no opinion" rather than a
                // deliberate clear — the iOS change DTO can only ever send [] or a populated
                // array (never null), and no UI produces a deliberate clear, so honoring []
                // here would let one device wipe another device's saved order.
                change.SubscriptionManualOrder is { Count: > 0 }
                    ? change.SubscriptionManualOrder
                    : stored?.SubscriptionManualOrder,
                // Null means the pushing client doesn't send these fields yet (see
                // UserSettingsChange) — keep whatever's stored rather than clobbering it.
                change.AutoAddNewEpisodesToUpNext ?? stored?.AutoAddNewEpisodesToUpNext ?? false,
                change.UpNextInsertPosition ?? stored?.UpNextInsertPosition ?? UpNextInsertPosition.Bottom,
                UpdatedAt: DateTimeOffset.UtcNow,
                DeviceId: deviceId),
            readStoredAsync: (id, ct) => ReadStoredSettingsAsync(id, ct),
            upsertAsync: (state, ct) => settingsContainer.UpsertItemAsync(state, new PartitionKey(userId), cancellationToken: ct),
            queryAllAsync: ct => QueryAllSettingsAsync(userId, ct),
            cancellationToken);

        return new SyncSettingsResult(result.ServerChanges, result.SyncedAt, result.Hash);
    }

    public Task<UserSettings> UpdateUnlistenedEpisodeCountAsync(
        string userId, UnlistenedEpisodeCount unlistenedEpisodeCount, CancellationToken cancellationToken) =>
        UpdateSettingsWithRetryAsync(
            userId, current => current with { UnlistenedEpisodeCount = unlistenedEpisodeCount }, cancellationToken);

    public Task<UserSettings> UpdateSubscriptionSortOrderAsync(
        string userId, SubscriptionSortOrder subscriptionSortOrder, CancellationToken cancellationToken) =>
        UpdateSettingsWithRetryAsync(
            userId, current => current with { SubscriptionSortOrder = subscriptionSortOrder }, cancellationToken);

    public Task<UserSettings> UpdateSubscriptionManualOrderAsync(
        string userId, IReadOnlyList<string> subscriptionManualOrder, CancellationToken cancellationToken) =>
        UpdateSettingsWithRetryAsync(
            userId, current => current with { SubscriptionManualOrder = subscriptionManualOrder }, cancellationToken);

    public async Task<ShowSettings> GetShowSettingsAsync(string userId, string showId, CancellationToken cancellationToken)
    {
        var id = ShowSettings.BuildId(userId, showId);
        try
        {
            var response = await settingsContainer.ReadItemAsync<ShowSettings>(
                id, new PartitionKey(id), cancellationToken: cancellationToken);
            return response.Resource;
        }
        catch (CosmosException ex) when (ex.StatusCode == HttpStatusCode.NotFound)
        {
            // No override document yet — hand back the default (no override) rather than
            // writing it, so reading settings never has a side effect, matching GetSettingsAsync.
            return ShowSettings.CreateDefault(userId, showId);
        }
    }

    public async Task<ShowSettings> UpdateShowUnlistenedEpisodeCountAsync(
        string userId, string showId, UnlistenedEpisodeCount? unlistenedEpisodeCount, CancellationToken cancellationToken)
    {
        var current = await GetShowSettingsAsync(userId, showId, cancellationToken);
        var updated = current with
        {
            UnlistenedEpisodeCount = unlistenedEpisodeCount,
            Version = current.Version + 1,
            UpdatedAt = DateTimeOffset.UtcNow,
            DeviceId = null,
        };

        var response = await settingsContainer.UpsertItemAsync(
            updated, new PartitionKey(updated.Id), cancellationToken: cancellationToken);
        return response.Resource;
    }

    public async Task<UnlistenedEpisodeCount> GetEffectiveUnlistenedEpisodeCountAsync(
        string userId, string showId, CancellationToken cancellationToken)
    {
        var showSettings = await GetShowSettingsAsync(userId, showId, cancellationToken);
        if (showSettings.UnlistenedEpisodeCount is { } showOverride)
        {
            return showOverride;
        }

        var userSettings = await GetSettingsAsync(userId, cancellationToken);
        return userSettings.UnlistenedEpisodeCount;
    }

    public Task<UserSettings> UpdateAutoArchiveRuleAsync(
        string userId, AutoArchiveRule autoArchiveRule, CancellationToken cancellationToken) =>
        UpdateSettingsWithRetryAsync(userId, current => current with { AutoArchiveRule = autoArchiveRule }, cancellationToken);

    public async Task<ShowSettings> UpdateShowAutoArchiveRuleAsync(
        string userId, string showId, AutoArchiveRule? autoArchiveRule, CancellationToken cancellationToken)
    {
        var current = await GetShowSettingsAsync(userId, showId, cancellationToken);
        var updated = current with
        {
            AutoArchiveRule = autoArchiveRule,
            Version = current.Version + 1,
            UpdatedAt = DateTimeOffset.UtcNow,
            DeviceId = null,
        };

        var response = await settingsContainer.UpsertItemAsync(
            updated, new PartitionKey(updated.Id), cancellationToken: cancellationToken);
        return response.Resource;
    }

    public async Task<AutoArchiveRule> GetEffectiveAutoArchiveRuleAsync(
        string userId, string showId, CancellationToken cancellationToken)
    {
        var showSettings = await GetShowSettingsAsync(userId, showId, cancellationToken);
        if (showSettings.AutoArchiveRule is { } showOverride)
        {
            return showOverride;
        }

        var userSettings = await GetSettingsAsync(userId, cancellationToken);
        return userSettings.AutoArchiveRule;
    }

    public Task<UserSettings> UpdateAutoSkipAsync(
        string userId, int autoSkipIntroSeconds, int autoSkipOutroSeconds, CancellationToken cancellationToken) =>
        UpdateSettingsWithRetryAsync(
            userId,
            current => current with { AutoSkipIntroSeconds = autoSkipIntroSeconds, AutoSkipOutroSeconds = autoSkipOutroSeconds },
            cancellationToken);

    public async Task<ShowSettings> UpdateShowAutoSkipAsync(
        string userId, string showId, int? autoSkipIntroSeconds, int? autoSkipOutroSeconds, CancellationToken cancellationToken)
    {
        var current = await GetShowSettingsAsync(userId, showId, cancellationToken);
        var updated = current with
        {
            AutoSkipIntroSeconds = autoSkipIntroSeconds,
            AutoSkipOutroSeconds = autoSkipOutroSeconds,
            Version = current.Version + 1,
            UpdatedAt = DateTimeOffset.UtcNow,
            DeviceId = null,
        };

        var response = await settingsContainer.UpsertItemAsync(
            updated, new PartitionKey(updated.Id), cancellationToken: cancellationToken);
        return response.Resource;
    }

    public async Task<(int IntroSeconds, int OutroSeconds)> GetEffectiveAutoSkipAsync(
        string userId, string showId, CancellationToken cancellationToken)
    {
        var showSettings = await GetShowSettingsAsync(userId, showId, cancellationToken);

        // Skip the UserSettings read entirely when both fields are already overridden at the
        // show level — matching how GetEffectiveAutoArchiveRuleAsync short-circuits on a
        // show-level override, avoiding an unnecessary extra point read in the common case.
        if (showSettings.AutoSkipIntroSeconds is { } introOverride && showSettings.AutoSkipOutroSeconds is { } outroOverride)
        {
            return (introOverride, outroOverride);
        }

        var userSettings = await GetSettingsAsync(userId, cancellationToken);
        var introSeconds = showSettings.AutoSkipIntroSeconds ?? userSettings.AutoSkipIntroSeconds;
        var outroSeconds = showSettings.AutoSkipOutroSeconds ?? userSettings.AutoSkipOutroSeconds;
        return (introSeconds, outroSeconds);
    }

    public Task<UserSettings> UpdatePlaybackSpeedAsync(
        string userId, float playbackSpeed, CancellationToken cancellationToken) =>
        UpdateSettingsWithRetryAsync(userId, current => current with { PlaybackSpeed = playbackSpeed }, cancellationToken);

    public async Task<ShowSettings> UpdateShowPlaybackSpeedAsync(
        string userId, string showId, float? playbackSpeed, CancellationToken cancellationToken)
    {
        var current = await GetShowSettingsAsync(userId, showId, cancellationToken);
        var updated = current with
        {
            PlaybackSpeed = playbackSpeed,
            Version = current.Version + 1,
            UpdatedAt = DateTimeOffset.UtcNow,
            DeviceId = null,
        };

        var response = await settingsContainer.UpsertItemAsync(
            updated, new PartitionKey(updated.Id), cancellationToken: cancellationToken);
        return response.Resource;
    }

    public async Task<float> GetEffectivePlaybackSpeedAsync(
        string userId, string showId, CancellationToken cancellationToken)
    {
        var showSettings = await GetShowSettingsAsync(userId, showId, cancellationToken);
        if (showSettings.PlaybackSpeed is { } showOverride)
        {
            return showOverride;
        }

        var userSettings = await GetSettingsAsync(userId, cancellationToken);
        return userSettings.PlaybackSpeed;
    }

    public Task<UserSettings> UpdateAutoDeleteRuleAsync(
        string userId, AutoDeleteRule autoDeleteRule, int autoDeleteAfterDays, CancellationToken cancellationToken) =>
        UpdateSettingsWithRetryAsync(
            userId,
            current => current with { AutoDeleteRule = autoDeleteRule, AutoDeleteAfterDays = autoDeleteAfterDays },
            cancellationToken);

    public Task<UserSettings> UpdateAutoDownloadNewEpisodesAsync(
        string userId, bool autoDownloadNewEpisodes, CancellationToken cancellationToken) =>
        UpdateSettingsWithRetryAsync(
            userId, current => current with { AutoDownloadNewEpisodes = autoDownloadNewEpisodes }, cancellationToken);

    public async Task<ShowSettings> UpdateShowAutoDownloadNewEpisodesAsync(
        string userId, string showId, bool? autoDownloadNewEpisodes, CancellationToken cancellationToken)
    {
        var current = await GetShowSettingsAsync(userId, showId, cancellationToken);
        var updated = current with
        {
            AutoDownloadNewEpisodes = autoDownloadNewEpisodes,
            Version = current.Version + 1,
            UpdatedAt = DateTimeOffset.UtcNow,
            DeviceId = null,
        };

        var response = await settingsContainer.UpsertItemAsync(
            updated, new PartitionKey(updated.Id), cancellationToken: cancellationToken);
        return response.Resource;
    }

    public async Task<bool> GetEffectiveAutoDownloadNewEpisodesAsync(
        string userId, string showId, CancellationToken cancellationToken)
    {
        var showSettings = await GetShowSettingsAsync(userId, showId, cancellationToken);
        if (showSettings.AutoDownloadNewEpisodes is { } showOverride)
        {
            return showOverride;
        }

        var userSettings = await GetSettingsAsync(userId, cancellationToken);
        return userSettings.AutoDownloadNewEpisodes;
    }

    public Task<UserSettings> UpdateAutoAddNewEpisodesToUpNextAsync(
        string userId, bool autoAddNewEpisodesToUpNext, CancellationToken cancellationToken) =>
        UpdateSettingsWithRetryAsync(
            userId, current => current with { AutoAddNewEpisodesToUpNext = autoAddNewEpisodesToUpNext }, cancellationToken);

    public async Task<ShowSettings> UpdateShowAutoAddNewEpisodesToUpNextAsync(
        string userId, string showId, bool? autoAddNewEpisodesToUpNext, CancellationToken cancellationToken)
    {
        var current = await GetShowSettingsAsync(userId, showId, cancellationToken);
        var updated = current with
        {
            AutoAddNewEpisodesToUpNext = autoAddNewEpisodesToUpNext,
            Version = current.Version + 1,
            UpdatedAt = DateTimeOffset.UtcNow,
            DeviceId = null,
        };

        var response = await settingsContainer.UpsertItemAsync(
            updated, new PartitionKey(updated.Id), cancellationToken: cancellationToken);
        return response.Resource;
    }

    public async Task<bool> GetEffectiveAutoAddNewEpisodesToUpNextAsync(
        string userId, string showId, CancellationToken cancellationToken)
    {
        var showSettings = await GetShowSettingsAsync(userId, showId, cancellationToken);
        if (showSettings.AutoAddNewEpisodesToUpNext is { } showOverride)
        {
            return showOverride;
        }

        var userSettings = await GetSettingsAsync(userId, cancellationToken);
        return userSettings.AutoAddNewEpisodesToUpNext;
    }

    public Task<UserSettings> UpdateUpNextInsertPositionAsync(
        string userId, UpNextInsertPosition upNextInsertPosition, CancellationToken cancellationToken) =>
        UpdateSettingsWithRetryAsync(
            userId, current => current with { UpNextInsertPosition = upNextInsertPosition }, cancellationToken);

    public Task<UserSettings> UpdateSmartSpeedAsync(
        string userId, bool smartSpeed, CancellationToken cancellationToken) =>
        UpdateSettingsWithRetryAsync(userId, current => current with { SmartSpeed = smartSpeed }, cancellationToken);

    public Task<UserSettings> UpdateSleepTimerDefaultDurationAsync(
        string userId, int sleepTimerDefaultDurationMinutes, CancellationToken cancellationToken) =>
        UpdateSettingsWithRetryAsync(
            userId,
            current => current with { SleepTimerDefaultDurationMinutes = sleepTimerDefaultDurationMinutes },
            cancellationToken);

    public async Task<ShowSettings> UpdateShowSmartSpeedAsync(
        string userId, string showId, bool? smartSpeed, CancellationToken cancellationToken)
    {
        var current = await GetShowSettingsAsync(userId, showId, cancellationToken);
        var updated = current with
        {
            SmartSpeed = smartSpeed,
            Version = current.Version + 1,
            UpdatedAt = DateTimeOffset.UtcNow,
            DeviceId = null,
        };

        var response = await settingsContainer.UpsertItemAsync(
            updated, new PartitionKey(updated.Id), cancellationToken: cancellationToken);
        return response.Resource;
    }

    public async Task<bool> GetEffectiveSmartSpeedAsync(
        string userId, string showId, CancellationToken cancellationToken)
    {
        var showSettings = await GetShowSettingsAsync(userId, showId, cancellationToken);
        if (showSettings.SmartSpeed is { } showOverride)
        {
            return showOverride;
        }

        var userSettings = await GetSettingsAsync(userId, cancellationToken);
        return userSettings.SmartSpeed;
    }

    public async Task<UserSettings> UpdateNotificationsEnabledAsync(
        string userId, bool notificationsEnabled, CancellationToken cancellationToken)
    {
        var current = await GetSettingsAsync(userId, cancellationToken);
        var updated = current with
        {
            NotificationsEnabled = notificationsEnabled,
            Version = current.Version + 1,
            UpdatedAt = DateTimeOffset.UtcNow,
            DeviceId = null,
        };

        var response = await settingsContainer.UpsertItemAsync(
            updated, new PartitionKey(userId), cancellationToken: cancellationToken);
        return response.Resource;
    }

    public async Task<ShowSettings> UpdateShowNotificationsEnabledAsync(
        string userId, string showId, bool? notificationsEnabled, CancellationToken cancellationToken)
    {
        var current = await GetShowSettingsAsync(userId, showId, cancellationToken);
        var updated = current with
        {
            NotificationsEnabled = notificationsEnabled,
            Version = current.Version + 1,
            UpdatedAt = DateTimeOffset.UtcNow,
            DeviceId = null,
        };

        var response = await settingsContainer.UpsertItemAsync(
            updated, new PartitionKey(updated.Id), cancellationToken: cancellationToken);
        return response.Resource;
    }

    public async Task<bool> GetEffectiveNotificationsEnabledAsync(
        string userId, string showId, CancellationToken cancellationToken)
    {
        var showSettings = await GetShowSettingsAsync(userId, showId, cancellationToken);
        if (showSettings.NotificationsEnabled is { } showOverride)
        {
            return showOverride;
        }

        var userSettings = await GetSettingsAsync(userId, cancellationToken);
        return userSettings.NotificationsEnabled;
    }
}
