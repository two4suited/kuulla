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

    private static readonly List<NewEpisode> NewEpisodes =
    [
        new(new Episode("ep-1", "show-1", "Monday Edition", DateTimeOffset.UtcNow, TimeSpan.FromMinutes(20), "https://audio", null, 128, 1024), AutoPlayed: false, ShowTitle: "The Daily", ShowArtworkUrl: "https://art/show-1.jpg"),
    ];

    private static TestHttpMessageHandler RouteHandler(
        Func<HttpRequestMessage, HttpResponseMessage>? onGetSubscriptions = null,
        Func<HttpRequestMessage, HttpResponseMessage>? onGetNewEpisodes = null,
        Func<HttpRequestMessage, HttpResponseMessage>? onGetInProgress = null,
        Func<HttpRequestMessage, HttpResponseMessage>? onDelete = null) => new(request =>
    {
        if (request.Method == HttpMethod.Delete)
        {
            return onDelete?.Invoke(request) ?? new HttpResponseMessage(HttpStatusCode.OK);
        }

        if (request.RequestUri!.AbsolutePath == "/api/episodes/in-progress-shows" && request.Method == HttpMethod.Get)
        {
            return onGetInProgress?.Invoke(request) ??
                new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(Array.Empty<string>()) };
        }

        if (request.RequestUri!.AbsolutePath == "/api/subscriptions" && request.Method == HttpMethod.Get)
        {
            return onGetSubscriptions?.Invoke(request) ??
                new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(Subscriptions) };
        }

        if (request.RequestUri.AbsolutePath == "/api/subscriptions/episodes" && request.Method == HttpMethod.Get)
        {
            return onGetNewEpisodes?.Invoke(request) ??
                new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(NewEpisodes) };
        }

        return new HttpResponseMessage(HttpStatusCode.NotFound);
    });

    [Fact]
    public void RendersSubscriptions_WhenLoadSucceeds()
    {
        AuthContext.SetAuthorized("user-1");
        ConfigureApi(RouteHandler());

        var cut = RenderComponent<Subscriptions>();

        cut.WaitForAssertion(() => Assert.Contains("The Daily", cut.Markup));
    }

    [Fact]
    public void ShowsUnplayedBadge_ForShowWithNewEpisodes()
    {
        AuthContext.SetAuthorized("user-1");
        ConfigureApi(RouteHandler());

        var cut = RenderComponent<Subscriptions>();

        cut.WaitForAssertion(() => Assert.Contains("badge", cut.Markup));
    }

    [Fact]
    public void ShowsInProgressBadge_ForShowWithInProgressEpisode()
    {
        AuthContext.SetAuthorized("user-1");
        ConfigureApi(RouteHandler(onGetInProgress: _ =>
            new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(new[] { "show-1" }) }));

        var cut = RenderComponent<Subscriptions>();

        cut.WaitForAssertion(() => Assert.Contains("In progress", cut.Markup));
    }

    [Fact]
    public void RendersSubscriptionsWithoutBadges_WhenUnplayedCountLoadFails()
    {
        AuthContext.SetAuthorized("user-1");
        ConfigureApi(RouteHandler(onGetNewEpisodes: _ => new HttpResponseMessage(HttpStatusCode.InternalServerError)));

        var cut = RenderComponent<Subscriptions>();

        cut.WaitForAssertion(() =>
        {
            Assert.Contains("The Daily", cut.Markup);
            Assert.DoesNotContain("Something went wrong", cut.Markup);
            Assert.DoesNotContain("badge", cut.Markup);
        });
    }

    [Fact]
    public void ShowsEmptyMessage_WhenNoSubscriptions()
    {
        AuthContext.SetAuthorized("user-1");
        ConfigureApi(RouteHandler(onGetSubscriptions: _ => new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(new List<Subscription>()) }));

        var cut = RenderComponent<Subscriptions>();

        cut.WaitForAssertion(() => Assert.Contains("haven't subscribed", cut.Markup));
    }

    [Fact]
    public void ShowsErrorMessage_WhenLoadFails()
    {
        AuthContext.SetAuthorized("user-1");
        ConfigureApi(RouteHandler(onGetSubscriptions: _ => new HttpResponseMessage(HttpStatusCode.InternalServerError)));

        var cut = RenderComponent<Subscriptions>();

        cut.WaitForAssertion(() => Assert.Contains("Something went wrong", cut.Markup));
    }

    [Fact]
    public void RemovesSubscription_WhenUnsubscribeConfirmed()
    {
        AuthContext.SetAuthorized("user-1");
        ConfigureApi(RouteHandler(onDelete: request =>
            request.RequestUri!.AbsolutePath == "/api/subscriptions/show-1"
                ? new HttpResponseMessage(HttpStatusCode.OK)
                : new HttpResponseMessage(HttpStatusCode.NotFound)));

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
