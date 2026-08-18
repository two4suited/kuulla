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
}
