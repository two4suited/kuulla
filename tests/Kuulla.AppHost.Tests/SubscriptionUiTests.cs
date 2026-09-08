using Microsoft.Playwright;
using Xunit;

namespace Kuulla.AppHost.Tests;

// Browser-level counterpart to SubscriptionFlowTests: drives subscribe/unsubscribe through the
// real Blazor Server UI via Playwright instead of calling the API directly.
[Collection(AppHostCollection.Name)]
public class SubscriptionUiTests(AppHostFixture fixture)
{
    [Fact]
    public async Task Subscribe_ThenUnsubscribe_RoundTripsThroughTheRealUi()
    {
        using var apiClient = fixture.CreateApiClient();
        var show = await WebTestHelpers.SeedShowAsync(apiClient, Guid.NewGuid().ToString("N"));

        var page = await fixture.NewPageAsync();
        try
        {
            await WebTestHelpers.SignInAsTestUserAsync(page);

            await page.GotoAsync($"/shows/{show.Id}");
            await page.GetByRole(AriaRole.Heading, new() { Name = show.Title }).WaitForAsync();

            var subscribeButton = page.GetByRole(AriaRole.Button, new() { Name = "Subscribe" });
            await subscribeButton.ClickAsync();
            await page.GetByRole(AriaRole.Button, new() { Name = "Unsubscribe" }).WaitForAsync();

            await page.GotoAsync("/subscriptions");
            // Grid tiles are artwork-only (#487); unsubscribe now lives on Show Detail, reached by
            // tapping the tile.
            await page.GetByText(show.Title).ClickAsync();
            await page.GetByRole(AriaRole.Heading, new() { Name = show.Title }).WaitForAsync();

            await page.GetByRole(AriaRole.Button, new() { Name = "Unsubscribe" }).ClickAsync();
            await page.GetByRole(AriaRole.Button, new() { Name = "Subscribe" }).WaitForAsync();

            await page.GotoAsync("/subscriptions");
            await page.GetByText("You haven't subscribed to any shows yet.").WaitForAsync();
        }
        finally
        {
            // Closes the page's owning context too, so its cookies/storage don't linger for
            // the rest of the (shared, collection-scoped) fixture's lifetime.
            await page.Context.CloseAsync();
        }
    }
}
