using System.Net;
using Microsoft.Azure.Cosmos;
using Microsoft.Extensions.DependencyInjection;
using Kuulla.Api.Models;
using Kuulla.Api.Services.Sync;
using StackExchange.Redis;

namespace Kuulla.Api.Services;

public class SettingsService(
    [FromKeyedServices("settings")] Container settingsContainer,
    IConnectionMultiplexer redis) : ISettingsService
{
    private readonly SyncSummaryCache<UserSettings> _syncSummaryCache = new(redis, "settings");

    // Field initializer can't reference _syncSummaryCache (CS0236), so the reconciler is built
    // lazily on first use instead, matching EpisodeStateService's workaround.
    private SyncReconciler<UserSettings, UserSettingsChange>? _reconciler;
    private SyncReconciler<UserSettings, UserSettingsChange> Reconciler => _reconciler ??= new(_syncSummaryCache);

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

    // Takes the just-written document directly rather than re-reading it from Cosmos — every
    // caller already has it from the UpsertItemAsync response, and a settings collection is
    // always exactly this one document, so there's nothing a re-read would learn that the
    // caller doesn't already know.
    private Task RecomputeSyncSummaryAsync(string userId, UserSettings current, CancellationToken cancellationToken) =>
        _syncSummaryCache.SetAsync(userId, SyncSummaryCache<UserSettings>.Compute([current]), cancellationToken);

    public async Task<SyncSettingsResult> SyncAsync(
        string userId,
        string deviceId,
        DateTimeOffset lastSyncedAt,
        string localHash,
        IReadOnlyList<UserSettingsChange> changes,
        CancellationToken cancellationToken)
    {
        var result = await Reconciler.ReconcileAsync(
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
                UpdatedAt: DateTimeOffset.UtcNow,
                DeviceId: deviceId),
            readStoredAsync: (id, ct) => ReadStoredSettingsAsync(id, ct),
            upsertAsync: (state, ct) => settingsContainer.UpsertItemAsync(state, new PartitionKey(userId), cancellationToken: ct),
            queryAllAsync: ct => QueryAllSettingsAsync(userId, ct),
            cancellationToken);

        return new SyncSettingsResult(result.ServerChanges, result.SyncedAt, result.Hash);
    }

    public async Task<UserSettings> UpdateUnlistenedEpisodeCountAsync(
        string userId, UnlistenedEpisodeCount unlistenedEpisodeCount, CancellationToken cancellationToken)
    {
        var current = await GetSettingsAsync(userId, cancellationToken);
        var updated = current with
        {
            UnlistenedEpisodeCount = unlistenedEpisodeCount,
            Version = current.Version + 1,
            UpdatedAt = DateTimeOffset.UtcNow,
        };

        var response = await settingsContainer.UpsertItemAsync(
            updated, new PartitionKey(userId), cancellationToken: cancellationToken);
        await RecomputeSyncSummaryAsync(userId, response.Resource, cancellationToken);
        return response.Resource;
    }

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

    public async Task<UserSettings> UpdateAutoArchiveRuleAsync(
        string userId, AutoArchiveRule autoArchiveRule, CancellationToken cancellationToken)
    {
        var current = await GetSettingsAsync(userId, cancellationToken);
        var updated = current with
        {
            AutoArchiveRule = autoArchiveRule,
            Version = current.Version + 1,
            UpdatedAt = DateTimeOffset.UtcNow,
        };

        var response = await settingsContainer.UpsertItemAsync(
            updated, new PartitionKey(userId), cancellationToken: cancellationToken);
        await RecomputeSyncSummaryAsync(userId, response.Resource, cancellationToken);
        return response.Resource;
    }

    public async Task<ShowSettings> UpdateShowAutoArchiveRuleAsync(
        string userId, string showId, AutoArchiveRule? autoArchiveRule, CancellationToken cancellationToken)
    {
        var current = await GetShowSettingsAsync(userId, showId, cancellationToken);
        var updated = current with
        {
            AutoArchiveRule = autoArchiveRule,
            Version = current.Version + 1,
            UpdatedAt = DateTimeOffset.UtcNow,
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

    public async Task<UserSettings> UpdateAutoSkipAsync(
        string userId, int autoSkipIntroSeconds, int autoSkipOutroSeconds, CancellationToken cancellationToken)
    {
        var current = await GetSettingsAsync(userId, cancellationToken);
        var updated = current with
        {
            AutoSkipIntroSeconds = autoSkipIntroSeconds,
            AutoSkipOutroSeconds = autoSkipOutroSeconds,
            Version = current.Version + 1,
            UpdatedAt = DateTimeOffset.UtcNow,
        };

        var response = await settingsContainer.UpsertItemAsync(
            updated, new PartitionKey(userId), cancellationToken: cancellationToken);
        await RecomputeSyncSummaryAsync(userId, response.Resource, cancellationToken);
        return response.Resource;
    }

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

    public async Task<UserSettings> UpdatePlaybackSpeedAsync(
        string userId, float playbackSpeed, CancellationToken cancellationToken)
    {
        var current = await GetSettingsAsync(userId, cancellationToken);
        var updated = current with
        {
            PlaybackSpeed = playbackSpeed,
            Version = current.Version + 1,
            UpdatedAt = DateTimeOffset.UtcNow,
        };

        var response = await settingsContainer.UpsertItemAsync(
            updated, new PartitionKey(userId), cancellationToken: cancellationToken);
        await RecomputeSyncSummaryAsync(userId, response.Resource, cancellationToken);
        return response.Resource;
    }

    public async Task<ShowSettings> UpdateShowPlaybackSpeedAsync(
        string userId, string showId, float? playbackSpeed, CancellationToken cancellationToken)
    {
        var current = await GetShowSettingsAsync(userId, showId, cancellationToken);
        var updated = current with
        {
            PlaybackSpeed = playbackSpeed,
            Version = current.Version + 1,
            UpdatedAt = DateTimeOffset.UtcNow,
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

    public async Task<UserSettings> UpdateAutoDeleteRuleAsync(
        string userId, AutoDeleteRule autoDeleteRule, int autoDeleteAfterDays, CancellationToken cancellationToken)
    {
        var current = await GetSettingsAsync(userId, cancellationToken);
        var updated = current with
        {
            AutoDeleteRule = autoDeleteRule,
            AutoDeleteAfterDays = autoDeleteAfterDays,
            Version = current.Version + 1,
            UpdatedAt = DateTimeOffset.UtcNow,
        };

        var response = await settingsContainer.UpsertItemAsync(
            updated, new PartitionKey(userId), cancellationToken: cancellationToken);
        await RecomputeSyncSummaryAsync(userId, response.Resource, cancellationToken);
        return response.Resource;
    }

    public async Task<UserSettings> UpdateAutoDownloadNewEpisodesAsync(
        string userId, bool autoDownloadNewEpisodes, CancellationToken cancellationToken)
    {
        var current = await GetSettingsAsync(userId, cancellationToken);
        var updated = current with
        {
            AutoDownloadNewEpisodes = autoDownloadNewEpisodes,
            Version = current.Version + 1,
            UpdatedAt = DateTimeOffset.UtcNow,
        };

        var response = await settingsContainer.UpsertItemAsync(
            updated, new PartitionKey(userId), cancellationToken: cancellationToken);
        await RecomputeSyncSummaryAsync(userId, response.Resource, cancellationToken);
        return response.Resource;
    }

    public async Task<ShowSettings> UpdateShowAutoDownloadNewEpisodesAsync(
        string userId, string showId, bool? autoDownloadNewEpisodes, CancellationToken cancellationToken)
    {
        var current = await GetShowSettingsAsync(userId, showId, cancellationToken);
        var updated = current with
        {
            AutoDownloadNewEpisodes = autoDownloadNewEpisodes,
            Version = current.Version + 1,
            UpdatedAt = DateTimeOffset.UtcNow,
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
}
