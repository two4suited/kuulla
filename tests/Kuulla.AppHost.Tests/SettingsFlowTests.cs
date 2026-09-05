using System.Net;
using System.Net.Http.Json;
using Xunit;

namespace Kuulla.AppHost.Tests;

[Collection(AppHostCollection.Name)]
public class SettingsFlowTests(AppHostFixture fixture)
{
    // End-to-end against the real API + Cosmos emulator (no mocks): a fresh user reads the
    // default settings, updates the unlistened episode count, then reads it back through the
    // actual Cosmos "settings" container.
    [Fact]
    public async Task GetThenUpdate_RoundTripsThroughRealCosmos()
    {
        using var client = fixture.CreateApiClient();
        await AuthenticateAsync(client);

        var defaultSettings = await client.GetFromJsonAsync<UserSettingsResponse>("/api/settings");
        Assert.Equal(5, defaultSettings?.UnlistenedEpisodeCount);
        Assert.Equal(1, defaultSettings?.Version);

        var updateResponse = await client.PutAsJsonAsync("/api/settings", new { UnlistenedEpisodeCount = 10 });
        Assert.Equal(HttpStatusCode.OK, updateResponse.StatusCode);
        var updated = await updateResponse.Content.ReadFromJsonAsync<UserSettingsResponse>();
        Assert.Equal(10, updated?.UnlistenedEpisodeCount);
        Assert.Equal(2, updated?.Version);

        var reread = await client.GetFromJsonAsync<UserSettingsResponse>("/api/settings");
        Assert.Equal(10, reread?.UnlistenedEpisodeCount);
        Assert.Equal(2, reread?.Version);
    }

    [Fact]
    public async Task Update_InvalidUnlistenedEpisodeCount_ReturnsBadRequest()
    {
        using var client = fixture.CreateApiClient();
        await AuthenticateAsync(client);

        var updateResponse = await client.PutAsJsonAsync("/api/settings", new { UnlistenedEpisodeCount = 999 });

        Assert.Equal(HttpStatusCode.BadRequest, updateResponse.StatusCode);
    }

    // End-to-end against the real API + Cosmos emulator: a fresh user reads default (no-override)
    // per-show settings, sets an override, reads it back, then clears it back to no-override.
    [Fact]
    public async Task ShowSettings_GetThenUpdateThenClear_RoundTripsThroughRealCosmos()
    {
        using var client = fixture.CreateApiClient();
        await AuthenticateAsync(client);
        const string showId = "show-1";

        var defaultSettings = await client.GetFromJsonAsync<ShowSettingsResponse>($"/api/settings/shows/{showId}");
        Assert.Equal(showId, defaultSettings?.ShowId);
        Assert.Null(defaultSettings?.UnlistenedEpisodeCount);
        Assert.Equal(1, defaultSettings?.Version);

        var updateResponse = await client.PutAsJsonAsync($"/api/settings/shows/{showId}", new { UnlistenedEpisodeCount = 2 });
        Assert.Equal(HttpStatusCode.OK, updateResponse.StatusCode);
        var updated = await updateResponse.Content.ReadFromJsonAsync<ShowSettingsResponse>();
        Assert.Equal(2, updated?.UnlistenedEpisodeCount);
        Assert.Equal(2, updated?.Version);

        var clearResponse = await client.PutAsJsonAsync($"/api/settings/shows/{showId}", new { UnlistenedEpisodeCount = (int?)null });
        Assert.Equal(HttpStatusCode.OK, clearResponse.StatusCode);
        var cleared = await clearResponse.Content.ReadFromJsonAsync<ShowSettingsResponse>();
        Assert.Null(cleared?.UnlistenedEpisodeCount);
        Assert.Equal(3, cleared?.Version);
    }

    [Fact]
    public async Task ShowSettings_Update_InvalidUnlistenedEpisodeCount_ReturnsBadRequest()
    {
        using var client = fixture.CreateApiClient();
        await AuthenticateAsync(client);

        var updateResponse = await client.PutAsJsonAsync("/api/settings/shows/show-1", new { UnlistenedEpisodeCount = 999 });

        Assert.Equal(HttpStatusCode.BadRequest, updateResponse.StatusCode);
    }

    // End-to-end coverage for the global + per-show notification-preference routes (#214) — not
    // just JSON binding/route wiring, but that clearing a per-show override with an explicit null
    // (not just omitting the field) actually round-trips through the real API + Cosmos emulator.
    [Fact]
    public async Task Notifications_UpdateThenRead_RoundTripsThroughRealCosmos()
    {
        using var client = fixture.CreateApiClient();
        // Own userId (see AuthenticateAsync's doc comment) — GetThenUpdate_RoundTripsThroughRealCosmos
        // above also writes the global UserSettings singleton for the default test user, and xUnit
        // doesn't guarantee ordering between the two.
        await AuthenticateAsync(client, userId: "settings-notifications-test-user");

        var defaultSettings = await client.GetFromJsonAsync<UserSettingsResponse>("/api/settings");
        Assert.True(defaultSettings?.NotificationsEnabled);

        var updateResponse = await client.PutAsJsonAsync("/api/settings/notifications", new { NotificationsEnabled = false });
        Assert.Equal(HttpStatusCode.OK, updateResponse.StatusCode);
        var updated = await updateResponse.Content.ReadFromJsonAsync<UserSettingsResponse>();
        Assert.False(updated?.NotificationsEnabled);

        var reread = await client.GetFromJsonAsync<UserSettingsResponse>("/api/settings");
        Assert.False(reread?.NotificationsEnabled);
    }

    [Fact]
    public async Task ShowNotifications_SetThenClear_RoundTripsThroughRealCosmos()
    {
        using var client = fixture.CreateApiClient();
        await AuthenticateAsync(client);
        const string showId = "show-notifications-1";

        var defaultSettings = await client.GetFromJsonAsync<ShowSettingsResponse>($"/api/settings/shows/{showId}");
        Assert.Null(defaultSettings?.NotificationsEnabled);

        var updateResponse = await client.PutAsJsonAsync(
            $"/api/settings/shows/{showId}/notifications", new { NotificationsEnabled = false });
        Assert.Equal(HttpStatusCode.OK, updateResponse.StatusCode);
        var updated = await updateResponse.Content.ReadFromJsonAsync<ShowSettingsResponse>();
        Assert.False(updated?.NotificationsEnabled);

        var clearResponse = await client.PutAsJsonAsync(
            $"/api/settings/shows/{showId}/notifications", new { NotificationsEnabled = (bool?)null });
        Assert.Equal(HttpStatusCode.OK, clearResponse.StatusCode);
        var cleared = await clearResponse.Content.ReadFromJsonAsync<ShowSettingsResponse>();
        Assert.Null(cleared?.NotificationsEnabled);
    }

    // End-to-end coverage for the sleep timer default duration route (#206) — real API +
    // Cosmos emulator, catching route wiring/JSON binding regressions the same way
    // Notifications_UpdateThenRead_RoundTripsThroughRealCosmos does above.
    [Fact]
    public async Task SleepTimerDefaultDuration_UpdateThenRead_RoundTripsThroughRealCosmos()
    {
        using var client = fixture.CreateApiClient();
        // Own userId, same rationale as Notifications_UpdateThenRead_RoundTripsThroughRealCosmos.
        await AuthenticateAsync(client, userId: "settings-sleep-timer-test-user");

        var defaultSettings = await client.GetFromJsonAsync<UserSettingsResponse>("/api/settings");
        Assert.Null(defaultSettings?.SleepTimerDefaultDurationMinutes);

        var updateResponse = await client.PutAsJsonAsync(
            "/api/settings/sleep-timer-default-duration", new { SleepTimerDefaultDurationMinutes = 30 });
        Assert.Equal(HttpStatusCode.OK, updateResponse.StatusCode);
        var updated = await updateResponse.Content.ReadFromJsonAsync<UserSettingsResponse>();
        Assert.Equal(30, updated?.SleepTimerDefaultDurationMinutes);

        var reread = await client.GetFromJsonAsync<UserSettingsResponse>("/api/settings");
        Assert.Equal(30, reread?.SleepTimerDefaultDurationMinutes);
    }

    [Fact]
    public async Task SleepTimerDefaultDuration_Update_InvalidValue_ReturnsBadRequest()
    {
        using var client = fixture.CreateApiClient();
        await AuthenticateAsync(client);

        var updateResponse = await client.PutAsJsonAsync(
            "/api/settings/sleep-timer-default-duration", new { SleepTimerDefaultDurationMinutes = 0 });

        Assert.Equal(HttpStatusCode.BadRequest, updateResponse.StatusCode);
    }

    [Fact]
    public async Task SubscriptionSortOrder_GetThenUpdate_RoundTripsThroughRealCosmos()
    {
        using var client = fixture.CreateApiClient();
        await AuthenticateAsync(client, userId: $"sort-user-{Guid.NewGuid():N}");

        var defaultSettings = await client.GetFromJsonAsync<UserSettingsResponse>("/api/settings");
        Assert.Equal(0, defaultSettings?.SubscriptionSortOrder); // Title

        var updateResponse = await client.PutAsJsonAsync(
            "/api/settings/subscription-sort-order", new { SubscriptionSortOrder = 2 }); // RecentlyAdded
        Assert.Equal(HttpStatusCode.OK, updateResponse.StatusCode);
        var updated = await updateResponse.Content.ReadFromJsonAsync<UserSettingsResponse>();
        Assert.Equal(2, updated?.SubscriptionSortOrder);

        var reread = await client.GetFromJsonAsync<UserSettingsResponse>("/api/settings");
        Assert.Equal(2, reread?.SubscriptionSortOrder);
    }

    [Fact]
    public async Task SubscriptionSortOrder_Update_InvalidValue_ReturnsBadRequest()
    {
        using var client = fixture.CreateApiClient();
        await AuthenticateAsync(client);

        var updateResponse = await client.PutAsJsonAsync(
            "/api/settings/subscription-sort-order", new { SubscriptionSortOrder = 99 });

        Assert.Equal(HttpStatusCode.BadRequest, updateResponse.StatusCode);
    }

    // Mints a local test token via /dev/test-token and attaches it to the client so subsequent
    // requests hit authenticated endpoints. userId defaults to /dev/test-token's own fixed
    // "local-test-user" subject — every test in this file that reads/writes the *global*
    // UserSettings document (a per-user singleton) must instead pass its own unique userId (see
    // PlaylistSeedFlowTests/DynamicPlaylistAutoOrderingFlowTests for the same pattern), or its
    // Version/state assertions can collide with any other global-settings test in this class,
    // since xUnit doesn't guarantee method execution order.
    private static async Task AuthenticateAsync(HttpClient client, string? userId = null)
    {
        var tokenResponse = await client.PostAsync(userId is null ? "/dev/test-token" : $"/dev/test-token?sub={userId}", content: null);
        Assert.Equal(HttpStatusCode.OK, tokenResponse.StatusCode);
        var tokenPayload = await tokenResponse.Content.ReadFromJsonAsync<TestTokenResponse>();
        Assert.False(string.IsNullOrEmpty(tokenPayload?.Token));

        client.DefaultRequestHeaders.Authorization = new("Bearer", tokenPayload!.Token);
    }

    private sealed record TestTokenResponse(string Token);

    private sealed record UserSettingsResponse(
        string UserId, int UnlistenedEpisodeCount, int Version, bool NotificationsEnabled, int? SleepTimerDefaultDurationMinutes,
        int SubscriptionSortOrder);

    private sealed record ShowSettingsResponse(string UserId, string ShowId, int? UnlistenedEpisodeCount, int Version, bool? NotificationsEnabled);
}
