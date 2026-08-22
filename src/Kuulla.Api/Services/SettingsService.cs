using System.Net;
using Microsoft.Azure.Cosmos;
using Microsoft.Extensions.DependencyInjection;
using Kuulla.Api.Models;

namespace Kuulla.Api.Services;

public class SettingsService(
    [FromKeyedServices("settings")] Container settingsContainer) : ISettingsService
{
    public async Task<UserSettings> GetSettingsAsync(string userId, CancellationToken cancellationToken)
    {
        try
        {
            var response = await settingsContainer.ReadItemAsync<UserSettings>(
                userId, new PartitionKey(userId), cancellationToken: cancellationToken);
            return response.Resource;
        }
        catch (CosmosException ex) when (ex.StatusCode == HttpStatusCode.NotFound)
        {
            // No document yet — hand back the default rather than writing it, so reading
            // settings never has a side effect. The first UpdateUnlistenedEpisodeCountAsync
            // call is what actually creates the document.
            return UserSettings.CreateDefault(userId);
        }
    }

    public async Task<UserSettings> UpdateUnlistenedEpisodeCountAsync(
        string userId, UnlistenedEpisodeCount unlistenedEpisodeCount, CancellationToken cancellationToken)
    {
        var current = await GetSettingsAsync(userId, cancellationToken);
        var updated = current with
        {
            UnlistenedEpisodeCount = unlistenedEpisodeCount,
            Version = current.Version + 1,
        };

        var response = await settingsContainer.UpsertItemAsync(
            updated, new PartitionKey(userId), cancellationToken: cancellationToken);
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
        };

        var response = await settingsContainer.UpsertItemAsync(
            updated, new PartitionKey(userId), cancellationToken: cancellationToken);
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
        };

        var response = await settingsContainer.UpsertItemAsync(
            updated, new PartitionKey(userId), cancellationToken: cancellationToken);
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
        };

        var response = await settingsContainer.UpsertItemAsync(
            updated, new PartitionKey(userId), cancellationToken: cancellationToken);
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
}
