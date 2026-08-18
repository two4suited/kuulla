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

    // Mints a local test token via /dev/test-token and attaches it to the client so subsequent
    // requests hit authenticated endpoints.
    private static async Task AuthenticateAsync(HttpClient client)
    {
        var tokenResponse = await client.PostAsync("/dev/test-token", content: null);
        Assert.Equal(HttpStatusCode.OK, tokenResponse.StatusCode);
        var tokenPayload = await tokenResponse.Content.ReadFromJsonAsync<TestTokenResponse>();
        Assert.False(string.IsNullOrEmpty(tokenPayload?.Token));

        client.DefaultRequestHeaders.Authorization = new("Bearer", tokenPayload!.Token);
    }

    private sealed record TestTokenResponse(string Token);

    private sealed record UserSettingsResponse(string UserId, int UnlistenedEpisodeCount, int Version);
}
