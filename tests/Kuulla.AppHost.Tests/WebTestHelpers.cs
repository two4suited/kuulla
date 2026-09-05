using System.Net.Http.Json;
using Kuulla.Api.Models;
using Microsoft.Playwright;
using Xunit;

namespace Kuulla.AppHost.Tests;

internal static class WebTestHelpers
{
    // Drives the same "Sign in as test user (local only)" form the NavMenu renders in
    // Development (see LoginDisplay.razor / Program.cs' /Account/LoginTest), instead of poking
    // the auth cookie directly, so the test also exercises the real sign-in link the way a user
    // would click it.
    public static async Task SignInAsTestUserAsync(IPage page)
    {
        await page.GotoAsync("/");
        await page.GetByRole(AriaRole.Button, new() { Name = "Sign in as test user (local only)" }).ClickAsync();
        await page.GetByText("Hello, Local Test User").WaitForAsync();
    }

    // Seeds a show directly into Cosmos through the API's own /dev/seed-show hook (the same one
    // SubscriptionFlowTests uses), so subscribe/unsubscribe tests don't depend on the real
    // iTunes directory being reachable or returning stable results.
    public static async Task<Show> SeedShowAsync(HttpClient apiClient, string idSuffix)
    {
        var show = new Show(
            $"e2e-show-{idSuffix}",
            Title: $"E2E Test Show {idSuffix}",
            Author: "E2E Test Author",
            FeedUrl: "https://example.com/feed.xml",
            ArtworkUrl: null,
            Description: "Seeded directly for browser end-to-end testing.",
            Categories: ["Technology"]);

        var response = await apiClient.PostAsJsonAsync("/dev/seed-show", show);
        Assert.True(response.IsSuccessStatusCode, $"Seeding show failed: {response.StatusCode}");

        return show;
    }
}
