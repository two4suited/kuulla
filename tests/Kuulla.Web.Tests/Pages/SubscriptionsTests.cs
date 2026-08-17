using System.Net;
using System.Net.Http.Json;
using Kuulla.Web.Components.Pages;
using Kuulla.Web.Models;

namespace Kuulla.Web.Tests.Pages;

public class SubscriptionsTests : WebTestContext
{
    private static readonly List<Subscription> Subscriptions =
    [
        new("sub-1", "show-1", "The Daily", "NYT", null, DateTimeOffset.UtcNow),
    ];

    [Fact]
    public void RendersSubscriptions_WhenLoadSucceeds()
    {
        ConfigureApi(TestHttpMessageHandler.Json(Subscriptions));

        var cut = RenderComponent<Subscriptions>();

        cut.WaitForAssertion(() => Assert.Contains("The Daily", cut.Markup));
    }

    [Fact]
    public void ShowsEmptyMessage_WhenNoSubscriptions()
    {
        ConfigureApi(TestHttpMessageHandler.Json(new List<Subscription>()));

        var cut = RenderComponent<Subscriptions>();

        cut.WaitForAssertion(() => Assert.Contains("haven't subscribed", cut.Markup));
    }

    [Fact]
    public void ShowsErrorMessage_WhenLoadFails()
    {
        ConfigureApi(TestHttpMessageHandler.Status(HttpStatusCode.InternalServerError));

        var cut = RenderComponent<Subscriptions>();

        cut.WaitForAssertion(() => Assert.Contains("Something went wrong", cut.Markup));
    }

    [Fact]
    public void RemovesSubscription_WhenUnsubscribeConfirmed()
    {
        ConfigureApi(new TestHttpMessageHandler(request =>
            request.Method == HttpMethod.Delete && request.RequestUri!.AbsolutePath == "/api/subscriptions/show-1"
                ? new HttpResponseMessage(HttpStatusCode.OK)
                : new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(Subscriptions) }));

        var cut = RenderComponent<Subscriptions>();
        cut.WaitForAssertion(() => Assert.Contains("Unsubscribe", cut.Markup));

        cut.Find("button.btn-outline-danger").Click();
        cut.WaitForAssertion(() => Assert.Contains("Confirm", cut.Markup));

        cut.Find("button.btn-danger").Click();

        cut.WaitForAssertion(() =>
        {
            Assert.DoesNotContain("The Daily", cut.Markup);
            Assert.DoesNotContain("Something went wrong", cut.Markup);
        });
    }
}
