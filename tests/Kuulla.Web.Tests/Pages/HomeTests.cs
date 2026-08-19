using System.Net;
using System.Net.Http.Json;
using Bunit;
using Kuulla.Web.Components.Pages;
using Kuulla.Web.Models;

namespace Kuulla.Web.Tests.Pages;

public class HomeTests : WebTestContext
{
    public HomeTests()
    {
        // Components/Sync/SyncStatusIndicator.razor.js isn't loadable under bunit's jsdom-less
        // runtime; Loose mode auto-mocks the dynamic import/register calls (see SyncStatusIndicatorTests).
        JSInterop.Mode = JSRuntimeMode.Loose;
    }

    private static readonly List<NewEpisode> NewEpisodes =
    [
        new(new Episode("ep-1", "show-1", "Monday Edition", DateTimeOffset.UtcNow, TimeSpan.FromMinutes(20), "https://audio", null, 128, 1024), AutoPlayed: false),
    ];

    private static readonly SyncEpisodesResponseStub EmptySync = new([], DateTimeOffset.UtcNow, "hash-1");

    private static TestHttpMessageHandler RouteHandler(
        Func<HttpRequestMessage, HttpResponseMessage>? onGetEpisodes = null,
        Func<HttpRequestMessage, HttpResponseMessage>? onSync = null,
        Func<HttpRequestMessage, HttpResponseMessage>? onPutState = null) => new(request =>
    {
        if (request.RequestUri!.AbsolutePath == "/api/subscriptions/episodes" && request.Method == HttpMethod.Get)
        {
            return onGetEpisodes?.Invoke(request) ??
                new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(NewEpisodes) };
        }

        if (request.RequestUri.AbsolutePath == "/api/sync/episodes" && request.Method == HttpMethod.Post)
        {
            return onSync?.Invoke(request) ??
                new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(EmptySync) };
        }

        if (request.RequestUri.AbsolutePath == "/api/episodes/ep-1/state" && request.Method == HttpMethod.Put)
        {
            return onPutState?.Invoke(request) ?? new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = JsonContent.Create(new EpisodeState("ep-1", "user-1", "ep-1", "show-1", 1200, true, DateTimeOffset.UtcNow, "web")),
            };
        }

        return new HttpResponseMessage(HttpStatusCode.NotFound);
    });

    [Fact]
    public void RendersNewEpisodes_WhenLoadSucceeds()
    {
        AuthContext.SetAuthorized("user-1");
        ConfigureApi(RouteHandler());

        var cut = RenderComponent<Home>();

        cut.WaitForAssertion(() => Assert.Contains("Monday Edition", cut.Markup));
    }

    [Fact]
    public void ShowsEmptyMessage_WhenNoNewEpisodes()
    {
        AuthContext.SetAuthorized("user-1");
        ConfigureApi(RouteHandler(onGetEpisodes: _ =>
            new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(new List<NewEpisode>()) }));

        var cut = RenderComponent<Home>();

        cut.WaitForAssertion(() => Assert.Contains("caught up", cut.Markup));
    }

    [Fact]
    public void ShowsErrorMessage_WhenLoadFails()
    {
        AuthContext.SetAuthorized("user-1");
        ConfigureApi(TestHttpMessageHandler.Status(HttpStatusCode.InternalServerError));

        var cut = RenderComponent<Home>();

        cut.WaitForAssertion(() => Assert.Contains("Something went wrong", cut.Markup));
    }

    [Fact]
    public void ShowsSignInPrompt_WhenNotAuthenticated()
    {
        ConfigureApi(RouteHandler());

        var cut = RenderComponent<Home>();

        cut.WaitForAssertion(() => Assert.Contains("log in", cut.Markup));
    }

    [Fact]
    public void RemovesEpisode_WhenMarkedAsPlayed()
    {
        AuthContext.SetAuthorized("user-1");
        ConfigureApi(RouteHandler());

        var cut = RenderComponent<Home>();
        cut.WaitForAssertion(() => Assert.Contains("Monday Edition", cut.Markup));

        cut.Find("button.btn-outline-secondary").Click();

        cut.WaitForAssertion(() =>
        {
            Assert.DoesNotContain("Monday Edition", cut.Markup);
            Assert.Contains("caught up", cut.Markup);
        });
    }

    [Fact]
    public void BootstrapSyncFailure_DoesNotHideAlreadyLoadedEpisodes()
    {
        AuthContext.SetAuthorized("user-1");
        ConfigureApi(RouteHandler(onSync: _ => new HttpResponseMessage(HttpStatusCode.InternalServerError)));

        var cut = RenderComponent<Home>();

        cut.WaitForAssertion(() =>
        {
            Assert.Contains("Monday Edition", cut.Markup);
            Assert.DoesNotContain("Something went wrong", cut.Markup);
        });
    }

    [Fact]
    public void MarkAsPlayed_StaysRemoved_WhenOnlyBookkeepingSyncFails()
    {
        AuthContext.SetAuthorized("user-1");
        var syncCallCount = 0;
        ConfigureApi(RouteHandler(onSync: _ =>
        {
            syncCallCount++;
            // First call is the bootstrap poll in OnInitializedAsync; the second is the
            // SyncOwnWriteAsync bookkeeping call after MarkAsPlayedAsync's write already succeeded.
            return syncCallCount == 1
                ? new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(EmptySync) }
                : new HttpResponseMessage(HttpStatusCode.InternalServerError);
        }));

        var cut = RenderComponent<Home>();
        cut.WaitForAssertion(() => Assert.Contains("Monday Edition", cut.Markup));

        cut.Find("button.btn-outline-secondary").Click();

        cut.WaitForAssertion(() =>
        {
            Assert.DoesNotContain("Monday Edition", cut.Markup);
            Assert.DoesNotContain("Something went wrong", cut.Markup);
        });
    }

    [Fact]
    public void ShowsAutoPlayedIndicatorAndRestoreButton_ForAutoPlayedEpisode()
    {
        AuthContext.SetAuthorized("user-1");
        var autoPlayed = new List<NewEpisode>
        {
            new(new Episode("ep-1", "show-1", "Monday Edition", DateTimeOffset.UtcNow, TimeSpan.FromMinutes(20), "https://audio", null, 128, 1024), AutoPlayed: true),
        };
        ConfigureApi(RouteHandler(onGetEpisodes: _ =>
            new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(autoPlayed) }));

        var cut = RenderComponent<Home>();

        cut.WaitForAssertion(() =>
        {
            Assert.Contains("Auto-marked played", cut.Markup);
            Assert.Contains("Restore", cut.Markup);
        });
    }

    [Fact]
    public void RestoringAutoPlayedEpisode_ClearsIndicatorAndKeepsEpisodeVisible()
    {
        AuthContext.SetAuthorized("user-1");
        var autoPlayed = new List<NewEpisode>
        {
            new(new Episode("ep-1", "show-1", "Monday Edition", DateTimeOffset.UtcNow, TimeSpan.FromMinutes(20), "https://audio", null, 128, 1024), AutoPlayed: true),
        };
        ConfigureApi(RouteHandler(
            onGetEpisodes: _ => new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(autoPlayed) },
            onPutState: _ => new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = JsonContent.Create(new EpisodeState("ep-1", "user-1", "ep-1", "show-1", 0, false, DateTimeOffset.UtcNow, "web", AutoPlayed: false)),
            }));

        var cut = RenderComponent<Home>();
        cut.WaitForAssertion(() => Assert.Contains("Restore", cut.Markup));

        cut.Find("button.btn-outline-secondary").Click();

        cut.WaitForAssertion(() =>
        {
            Assert.Contains("Monday Edition", cut.Markup);
            Assert.DoesNotContain("Auto-marked played", cut.Markup);
            Assert.Contains("Mark as played", cut.Markup);
        });
    }

    private sealed record SyncEpisodesResponseStub(IReadOnlyList<EpisodeState> ServerChanges, DateTimeOffset SyncedAt, string Hash);
}
