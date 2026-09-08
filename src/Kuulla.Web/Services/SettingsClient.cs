using System.Net.Http.Json;
using System.Text.Json;
using Kuulla.Web.Models;
using Kuulla.Web.Services.Sync;

namespace Kuulla.Web.Services;

public class SettingsClient(KuullaApiClient apiClient)
{
    private const string DeviceId = "web";

    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    public async Task<UserSettings> GetSettingsAsync(CancellationToken cancellationToken = default)
    {
        var client = await apiClient.CreateClientAsync();
        var response = await client.GetAsync("api/settings", cancellationToken);
        response.EnsureSuccessStatusCode();
        return (await response.Content.ReadFromJsonAsync<UserSettings>(JsonOptions, cancellationToken))!;
    }

    public async Task<UserSettings> UpdateUnlistenedEpisodeCountAsync(
        UnlistenedEpisodeCount unlistenedEpisodeCount, CancellationToken cancellationToken = default)
    {
        var client = await apiClient.CreateClientAsync();
        var response = await client.PutAsJsonAsync(
            "api/settings", new { UnlistenedEpisodeCount = unlistenedEpisodeCount }, JsonOptions, cancellationToken);
        response.EnsureSuccessStatusCode();
        return (await response.Content.ReadFromJsonAsync<UserSettings>(JsonOptions, cancellationToken))!;
    }

    public async Task<UserSettings> UpdateSubscriptionSortOrderAsync(
        SubscriptionSortOrder subscriptionSortOrder, CancellationToken cancellationToken = default)
    {
        var client = await apiClient.CreateClientAsync();
        var response = await client.PutAsJsonAsync(
            "api/settings/subscription-sort-order",
            new { SubscriptionSortOrder = subscriptionSortOrder }, JsonOptions, cancellationToken);
        response.EnsureSuccessStatusCode();
        return (await response.Content.ReadFromJsonAsync<UserSettings>(JsonOptions, cancellationToken))!;
    }

    public async Task<UserSettings> UpdateSubscriptionManualOrderAsync(
        IReadOnlyList<string> showIds, CancellationToken cancellationToken = default)
    {
        var client = await apiClient.CreateClientAsync();
        var response = await client.PutAsJsonAsync(
            "api/settings/subscription-manual-order", new { ShowIds = showIds }, JsonOptions, cancellationToken);
        response.EnsureSuccessStatusCode();
        return (await response.Content.ReadFromJsonAsync<UserSettings>(JsonOptions, cancellationToken))!;
    }

    public async Task<UserSettings> UpdateHideCaughtUpShowsAsync(
        bool hideCaughtUpShows, CancellationToken cancellationToken = default)
    {
        var client = await apiClient.CreateClientAsync();
        var response = await client.PutAsJsonAsync(
            "api/settings/hide-caught-up-shows",
            new { HideCaughtUpShows = hideCaughtUpShows }, JsonOptions, cancellationToken);
        response.EnsureSuccessStatusCode();
        return (await response.Content.ReadFromJsonAsync<UserSettings>(JsonOptions, cancellationToken))!;
    }

    public async Task<ShowSettings> GetShowSettingsAsync(string showId, CancellationToken cancellationToken = default)
    {
        var client = await apiClient.CreateClientAsync();
        var response = await client.GetAsync($"api/settings/shows/{Uri.EscapeDataString(showId)}", cancellationToken);
        response.EnsureSuccessStatusCode();
        return (await response.Content.ReadFromJsonAsync<ShowSettings>(JsonOptions, cancellationToken))!;
    }

    public async Task<ShowSettings> UpdateShowUnlistenedEpisodeCountAsync(
        string showId, UnlistenedEpisodeCount? unlistenedEpisodeCount, CancellationToken cancellationToken = default)
    {
        var client = await apiClient.CreateClientAsync();
        var response = await client.PutAsJsonAsync(
            $"api/settings/shows/{Uri.EscapeDataString(showId)}",
            new { UnlistenedEpisodeCount = unlistenedEpisodeCount }, JsonOptions, cancellationToken);
        response.EnsureSuccessStatusCode();
        return (await response.Content.ReadFromJsonAsync<ShowSettings>(JsonOptions, cancellationToken))!;
    }

    public async Task<UserSettings> UpdateAutoArchiveRuleAsync(
        AutoArchiveRule autoArchiveRule, CancellationToken cancellationToken = default)
    {
        var client = await apiClient.CreateClientAsync();
        var response = await client.PutAsJsonAsync(
            "api/settings/auto-archive", new { AutoArchiveRule = autoArchiveRule }, JsonOptions, cancellationToken);
        response.EnsureSuccessStatusCode();
        return (await response.Content.ReadFromJsonAsync<UserSettings>(JsonOptions, cancellationToken))!;
    }

    public async Task<ShowSettings> UpdateShowAutoArchiveRuleAsync(
        string showId, AutoArchiveRule? autoArchiveRule, CancellationToken cancellationToken = default)
    {
        var client = await apiClient.CreateClientAsync();
        var response = await client.PutAsJsonAsync(
            $"api/settings/shows/{Uri.EscapeDataString(showId)}/auto-archive",
            new { AutoArchiveRule = autoArchiveRule }, JsonOptions, cancellationToken);
        response.EnsureSuccessStatusCode();
        return (await response.Content.ReadFromJsonAsync<ShowSettings>(JsonOptions, cancellationToken))!;
    }

    public async Task<ShowSettings> UpdateShowAutoSkipAsync(
        string showId, int? autoSkipIntroSeconds, int? autoSkipOutroSeconds,
        CancellationToken cancellationToken = default)
    {
        var client = await apiClient.CreateClientAsync();
        var response = await client.PutAsJsonAsync(
            $"api/settings/shows/{Uri.EscapeDataString(showId)}/auto-skip",
            new { AutoSkipIntroSeconds = autoSkipIntroSeconds, AutoSkipOutroSeconds = autoSkipOutroSeconds },
            JsonOptions, cancellationToken);
        response.EnsureSuccessStatusCode();
        return (await response.Content.ReadFromJsonAsync<ShowSettings>(JsonOptions, cancellationToken))!;
    }

    public async Task<ShowSettings> UpdateShowPlaybackSpeedAsync(
        string showId, float? playbackSpeed, CancellationToken cancellationToken = default)
    {
        var client = await apiClient.CreateClientAsync();
        var response = await client.PutAsJsonAsync(
            $"api/settings/shows/{Uri.EscapeDataString(showId)}/playback-speed",
            new { PlaybackSpeed = playbackSpeed }, JsonOptions, cancellationToken);
        response.EnsureSuccessStatusCode();
        return (await response.Content.ReadFromJsonAsync<ShowSettings>(JsonOptions, cancellationToken))!;
    }

    public async Task<ShowSettings> UpdateShowSmartSpeedAsync(
        string showId, bool? smartSpeed, CancellationToken cancellationToken = default)
    {
        var client = await apiClient.CreateClientAsync();
        var response = await client.PutAsJsonAsync(
            $"api/settings/shows/{Uri.EscapeDataString(showId)}/smart-speed",
            new { SmartSpeed = smartSpeed }, JsonOptions, cancellationToken);
        response.EnsureSuccessStatusCode();
        return (await response.Content.ReadFromJsonAsync<ShowSettings>(JsonOptions, cancellationToken))!;
    }

    public async Task<ShowSettings> UpdateShowNotificationsEnabledAsync(
        string showId, bool? notificationsEnabled, CancellationToken cancellationToken = default)
    {
        var client = await apiClient.CreateClientAsync();
        var response = await client.PutAsJsonAsync(
            $"api/settings/shows/{Uri.EscapeDataString(showId)}/notifications",
            new { NotificationsEnabled = notificationsEnabled }, JsonOptions, cancellationToken);
        response.EnsureSuccessStatusCode();
        return (await response.Content.ReadFromJsonAsync<ShowSettings>(JsonOptions, cancellationToken))!;
    }

    public async Task<UserSettings> UpdateAutoSkipAsync(
        int autoSkipIntroSeconds, int autoSkipOutroSeconds, CancellationToken cancellationToken = default)
    {
        var client = await apiClient.CreateClientAsync();
        var response = await client.PutAsJsonAsync(
            "api/settings/auto-skip",
            new { AutoSkipIntroSeconds = autoSkipIntroSeconds, AutoSkipOutroSeconds = autoSkipOutroSeconds },
            JsonOptions, cancellationToken);
        response.EnsureSuccessStatusCode();
        return (await response.Content.ReadFromJsonAsync<UserSettings>(JsonOptions, cancellationToken))!;
    }

    public async Task<UserSettings> UpdatePlaybackSpeedAsync(
        float playbackSpeed, CancellationToken cancellationToken = default)
    {
        var client = await apiClient.CreateClientAsync();
        var response = await client.PutAsJsonAsync(
            "api/settings/playback-speed", new { PlaybackSpeed = playbackSpeed }, JsonOptions, cancellationToken);
        response.EnsureSuccessStatusCode();
        return (await response.Content.ReadFromJsonAsync<UserSettings>(JsonOptions, cancellationToken))!;
    }

    public async Task<UserSettings> UpdateAutoDeleteRuleAsync(
        AutoDeleteRule autoDeleteRule, int autoDeleteAfterDays, CancellationToken cancellationToken = default)
    {
        var client = await apiClient.CreateClientAsync();
        var response = await client.PutAsJsonAsync(
            "api/settings/auto-delete",
            new { AutoDeleteRule = autoDeleteRule, AutoDeleteAfterDays = autoDeleteAfterDays },
            JsonOptions, cancellationToken);
        response.EnsureSuccessStatusCode();
        return (await response.Content.ReadFromJsonAsync<UserSettings>(JsonOptions, cancellationToken))!;
    }

    public async Task<ShowSettings> UpdateShowAutoDeleteRuleAsync(
        string showId, AutoDeleteRule? autoDeleteRule, int? autoDeleteAfterDays, CancellationToken cancellationToken = default)
    {
        var client = await apiClient.CreateClientAsync();
        var response = await client.PutAsJsonAsync(
            $"api/settings/shows/{Uri.EscapeDataString(showId)}/auto-delete",
            new { AutoDeleteRule = autoDeleteRule, AutoDeleteAfterDays = autoDeleteAfterDays },
            JsonOptions, cancellationToken);
        response.EnsureSuccessStatusCode();
        return (await response.Content.ReadFromJsonAsync<ShowSettings>(JsonOptions, cancellationToken))!;
    }

    public async Task<UserSettings> UpdateAutoDownloadNewEpisodesAsync(
        bool autoDownloadNewEpisodes, CancellationToken cancellationToken = default)
    {
        var client = await apiClient.CreateClientAsync();
        var response = await client.PutAsJsonAsync(
            "api/settings/auto-download", new { AutoDownloadNewEpisodes = autoDownloadNewEpisodes }, JsonOptions, cancellationToken);
        response.EnsureSuccessStatusCode();
        return (await response.Content.ReadFromJsonAsync<UserSettings>(JsonOptions, cancellationToken))!;
    }

    public async Task<ShowSettings> UpdateShowAutoDownloadNewEpisodesAsync(
        string showId, bool? autoDownloadNewEpisodes, CancellationToken cancellationToken = default)
    {
        var client = await apiClient.CreateClientAsync();
        var response = await client.PutAsJsonAsync(
            $"api/settings/shows/{Uri.EscapeDataString(showId)}/auto-download",
            new { AutoDownloadNewEpisodes = autoDownloadNewEpisodes }, JsonOptions, cancellationToken);
        response.EnsureSuccessStatusCode();
        return (await response.Content.ReadFromJsonAsync<ShowSettings>(JsonOptions, cancellationToken))!;
    }

    public async Task<UserSettings> UpdateAutoAddNewEpisodesToUpNextAsync(
        bool autoAddNewEpisodesToUpNext, CancellationToken cancellationToken = default)
    {
        var client = await apiClient.CreateClientAsync();
        var response = await client.PutAsJsonAsync(
            "api/settings/auto-add-up-next",
            new { AutoAddNewEpisodesToUpNext = autoAddNewEpisodesToUpNext }, JsonOptions, cancellationToken);
        response.EnsureSuccessStatusCode();
        return (await response.Content.ReadFromJsonAsync<UserSettings>(JsonOptions, cancellationToken))!;
    }

    public async Task<ShowSettings> UpdateShowAutoAddNewEpisodesToUpNextAsync(
        string showId, bool? autoAddNewEpisodesToUpNext, CancellationToken cancellationToken = default)
    {
        var client = await apiClient.CreateClientAsync();
        var response = await client.PutAsJsonAsync(
            $"api/settings/shows/{Uri.EscapeDataString(showId)}/auto-add-up-next",
            new { AutoAddNewEpisodesToUpNext = autoAddNewEpisodesToUpNext }, JsonOptions, cancellationToken);
        response.EnsureSuccessStatusCode();
        return (await response.Content.ReadFromJsonAsync<ShowSettings>(JsonOptions, cancellationToken))!;
    }

    public async Task<UserSettings> UpdateUpNextInsertPositionAsync(
        UpNextInsertPosition upNextInsertPosition, CancellationToken cancellationToken = default)
    {
        var client = await apiClient.CreateClientAsync();
        var response = await client.PutAsJsonAsync(
            "api/settings/up-next-insert-position",
            new { UpNextInsertPosition = upNextInsertPosition }, JsonOptions, cancellationToken);
        response.EnsureSuccessStatusCode();
        return (await response.Content.ReadFromJsonAsync<UserSettings>(JsonOptions, cancellationToken))!;
    }

    public async Task<ShowSettings> UpdateShowUpNextInsertPositionAsync(
        string showId, UpNextInsertPosition? upNextInsertPosition, CancellationToken cancellationToken = default)
    {
        var client = await apiClient.CreateClientAsync();
        var response = await client.PutAsJsonAsync(
            $"api/settings/shows/{Uri.EscapeDataString(showId)}/up-next-insert-position",
            new { UpNextInsertPosition = upNextInsertPosition }, JsonOptions, cancellationToken);
        response.EnsureSuccessStatusCode();
        return (await response.Content.ReadFromJsonAsync<ShowSettings>(JsonOptions, cancellationToken))!;
    }

    public async Task<UserSettings> UpdateSmartSpeedAsync(
        bool smartSpeed, CancellationToken cancellationToken = default)
    {
        var client = await apiClient.CreateClientAsync();
        var response = await client.PutAsJsonAsync(
            "api/settings/smart-speed", new { SmartSpeed = smartSpeed }, JsonOptions, cancellationToken);
        response.EnsureSuccessStatusCode();
        return (await response.Content.ReadFromJsonAsync<UserSettings>(JsonOptions, cancellationToken))!;
    }

    public async Task<UserSettings> UpdateSleepTimerDefaultDurationAsync(
        int sleepTimerDefaultDurationMinutes, CancellationToken cancellationToken = default)
    {
        var client = await apiClient.CreateClientAsync();
        var response = await client.PutAsJsonAsync(
            "api/settings/sleep-timer-default-duration",
            new { SleepTimerDefaultDurationMinutes = sleepTimerDefaultDurationMinutes }, JsonOptions, cancellationToken);
        response.EnsureSuccessStatusCode();
        return (await response.Content.ReadFromJsonAsync<UserSettings>(JsonOptions, cancellationToken))!;
    }

    // Polls (empty changes) or pushes (one change) via POST /api/sync/settings, mirroring
    // EpisodeStateClient.SyncAsync — see docs/sync-conventions.md.
    public async Task<SyncCheckResult<UserSettings>> SyncAsync(
        string localHash, DateTimeOffset lastSyncedAt, CancellationToken cancellationToken = default)
    {
        var client = await apiClient.CreateClientAsync();
        var body = new
        {
            DeviceId,
            LastSyncedAt = lastSyncedAt,
            LocalHash = localHash,
            Changes = Array.Empty<object>(),
        };
        var response = await client.PostAsJsonAsync("api/sync/settings", body, JsonOptions, cancellationToken);
        response.EnsureSuccessStatusCode();
        // The API's SyncSettingsResult and SyncCheckResult<T> already share the same
        // (ServerChanges, SyncedAt, Hash) shape, so this deserializes straight into it rather
        // than through a redundant private mirror record.
        return (await response.Content.ReadFromJsonAsync<SyncCheckResult<UserSettings>>(JsonOptions, cancellationToken))!;
    }
}
