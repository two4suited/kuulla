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
}
