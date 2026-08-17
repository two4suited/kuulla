using Microsoft.Playwright;
using Xunit;

namespace Kuulla.Web.E2E;

[Collection(WebAppCollection.Name)]
public class SubscriptionTests(WebAppFixture fixture)
{
    [Fact]
    public async Task Subscribe_ThenUnsubscribe_RoundTripsThroughTheRealUi()
    {
        using var apiClient = fixture.CreateApiClient();
        var show = await WebTestHelpers.SeedShowAsync(apiClient, Guid.NewGuid().ToString("N"));

        var page = await fixture.NewPageAsync();
        await WebTestHelpers.SignInAsTestUserAsync(page);

        await page.GotoAsync($"/shows/{show.Id}");
        await page.GetByRole(AriaRole.Heading, new() { Name = show.Title }).WaitForAsync();

        var subscribeButton = page.GetByRole(AriaRole.Button, new() { Name = "Subscribe" });
        await subscribeButton.ClickAsync();
        await page.GetByRole(AriaRole.Button, new() { Name = "Unsubscribe" }).WaitForAsync();

        await page.GotoAsync("/subscriptions");
        await page.GetByText(show.Title).WaitForAsync();

        await page.GetByRole(AriaRole.Button, new() { Name = "Unsubscribe" }).ClickAsync();
        await page.GetByRole(AriaRole.Button, new() { Name = "Confirm" }).ClickAsync();

        await page.GetByText("You haven't subscribed to any shows yet.").WaitForAsync();
    }
}
