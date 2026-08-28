using System.Net;
using System.Net.Http.Json;
using Kuulla.Web.Components.Pages;
using Kuulla.Web.Models;
using Microsoft.AspNetCore.Components;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Moq;

namespace Kuulla.Web.Tests.Pages;

public class HomeTests : WebTestContext
{
    private static readonly List<Subscription> Subscriptions =
    [
        new("sub-1", "show-1", "The Daily", "NYT", null, DateTimeOffset.UtcNow),
    ];

    private static readonly List<Playlist> Playlists =
    [
        new("pl-1", "Weekend Listening", PlaylistType.Manual, [new("ep-1", "show-1", DateTimeOffset.UtcNow, "a0")], DateTimeOffset.UtcNow, DateTimeOffset.UtcNow),
    ];

    private static readonly List<NewEpisode> NewEpisodes =
    [
        new(new Episode("ep-1", "show-1", "Monday Edition", DateTimeOffset.UtcNow, TimeSpan.FromMinutes(20), "https://audio", null, 128, 1024), AutoPlayed: false),
    ];

    private static TestHttpMessageHandler RouteHandler(
        Func<HttpRequestMessage, HttpResponseMessage>? onGetSubscriptions = null,
        Func<HttpRequestMessage, HttpResponseMessage>? onGetPlaylists = null,
        Func<HttpRequestMessage, HttpResponseMessage>? onGetNewEpisodes = null) => new(request =>
    {
        if (request.RequestUri!.AbsolutePath == "/api/subscriptions" && request.Method == HttpMethod.Get)
        {
            return onGetSubscriptions?.Invoke(request) ??
                new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(Subscriptions) };
        }

        if (request.RequestUri.AbsolutePath == "/api/playlists" && request.Method == HttpMethod.Get)
        {
            return onGetPlaylists?.Invoke(request) ??
                new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(Playlists) };
        }

        if (request.RequestUri.AbsolutePath == "/api/subscriptions/episodes" && request.Method == HttpMethod.Get)
        {
            return onGetNewEpisodes?.Invoke(request) ??
                new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(NewEpisodes) };
        }

        return new HttpResponseMessage(HttpStatusCode.NotFound);
    });

    [Fact]
    public void RendersShowsAndPlaylists_WhenLoadSucceeds()
    {
        AuthContext.SetAuthorized("user-1");
        ConfigureApi(RouteHandler());

        var cut = RenderComponent<Home>();

        cut.WaitForAssertion(() =>
        {
            Assert.Contains("The Daily", cut.Markup);
            Assert.Contains("Weekend Listening", cut.Markup);
            Assert.Contains("Up Next", cut.Markup);
            Assert.Contains("Downloaded", cut.Markup);
        });
    }

    [Fact]
    public void ShowsUnplayedBadge_ForShowWithNewEpisodes()
    {
        AuthContext.SetAuthorized("user-1");
        ConfigureApi(RouteHandler());

        var cut = RenderComponent<Home>();

        cut.WaitForAssertion(() => Assert.Contains("badge", cut.Markup));
    }

    [Fact]
    public void ShowsEmptyMessage_WhenNoSubscriptions()
    {
        AuthContext.SetAuthorized("user-1");
        ConfigureApi(RouteHandler(
            onGetSubscriptions: _ => new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(new List<Subscription>()) }));

        var cut = RenderComponent<Home>();

        cut.WaitForAssertion(() => Assert.Contains("haven't subscribed", cut.Markup));
    }

    [Fact]
    public void ShowsErrorMessage_WhenShowsLoadFails()
    {
        AuthContext.SetAuthorized("user-1");
        ConfigureApi(RouteHandler(onGetSubscriptions: _ => new HttpResponseMessage(HttpStatusCode.InternalServerError)));

        var cut = RenderComponent<Home>();

        cut.WaitForAssertion(() => Assert.Contains("Something went wrong", cut.Markup));
    }

    [Fact]
    public void RendersShowsWithoutBadges_WhenUnplayedCountLoadFails()
    {
        AuthContext.SetAuthorized("user-1");
        ConfigureApi(RouteHandler(onGetNewEpisodes: _ => new HttpResponseMessage(HttpStatusCode.InternalServerError)));

        var cut = RenderComponent<Home>();

        cut.WaitForAssertion(() =>
        {
            Assert.Contains("The Daily", cut.Markup);
            Assert.DoesNotContain("Something went wrong", cut.Markup);
            Assert.DoesNotContain("badge", cut.Markup);
        });
    }

    [Fact]
    public void ShowsErrorMessage_WhenPlaylistsLoadFails()
    {
        AuthContext.SetAuthorized("user-1");
        ConfigureApi(RouteHandler(onGetPlaylists: _ => new HttpResponseMessage(HttpStatusCode.InternalServerError)));

        var cut = RenderComponent<Home>();

        cut.WaitForAssertion(() => Assert.Contains("Something went wrong", cut.Markup));
    }

    [Fact]
    public void ShowsLandingPage_WhenNotAuthenticated()
    {
        ConfigureApi(RouteHandler());
        // The landing page's header renders <LoginDisplay />, which reads IHostEnvironment.
        var environment = new Mock<IHostEnvironment>();
        environment.SetupGet(e => e.EnvironmentName).Returns(Environments.Production);
        Services.AddSingleton(environment.Object);

        var cut = RenderComponent<Home>();

        // A logged-out visit to "/" shows the marketing landing page and redirects to /welcome.
        cut.WaitForAssertion(() => Assert.Contains("Pause here.", cut.Markup));
        Assert.EndsWith("/welcome", Services.GetRequiredService<NavigationManager>().Uri);
    }
}
