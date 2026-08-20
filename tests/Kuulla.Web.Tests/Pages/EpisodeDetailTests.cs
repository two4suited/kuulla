using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using Bunit;
using Kuulla.Web.Components.Pages;
using Kuulla.Web.Models;

namespace Kuulla.Web.Tests.Pages;

public class EpisodeDetailTests : WebTestContext
{
    public EpisodeDetailTests()
    {
        // Components/Pages/EpisodeDetail.razor.js isn't loadable under bunit's jsdom-less runtime;
        // Loose mode auto-mocks the dynamic import/attach calls (see SyncStatusIndicatorTests).
        JSInterop.Mode = JSRuntimeMode.Loose;
    }

    private static readonly Episode TestEpisode = new(
        "ep-1", "show-1", "Monday Edition", DateTimeOffset.UtcNow, TimeSpan.FromMinutes(20),
        "https://audio", "Show notes here", 128, 1024);

    private static readonly EpisodeState InProgressState = new(
        "ep-1", "user-1", "ep-1", "show-1", 300, false, DateTimeOffset.UtcNow, "device-1");

    private static readonly EpisodeState AutoPlayedState = new(
        "ep-1", "user-1", "ep-1", "show-1", 1200, true, DateTimeOffset.UtcNow, null, AutoPlayed: true);

    private static TestHttpMessageHandler RouteHandler(
        Func<HttpRequestMessage, HttpResponseMessage>? onGetState = null,
        Func<HttpRequestMessage, HttpResponseMessage>? onPutState = null) => new(request =>
    {
        if (request.RequestUri!.AbsolutePath == "/api/shows/show-1/episodes/ep-1" && request.Method == HttpMethod.Get)
        {
            return new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(TestEpisode) };
        }

        if (request.RequestUri.AbsolutePath == "/api/episodes/ep-1/state" && request.Method == HttpMethod.Get)
        {
            return onGetState?.Invoke(request) ?? new HttpResponseMessage(HttpStatusCode.NotFound);
        }

        if (request.RequestUri.AbsolutePath == "/api/episodes/ep-1/state" && request.Method == HttpMethod.Put)
        {
            return onPutState?.Invoke(request) ?? new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = JsonContent.Create(InProgressState with { Completed = true, PositionSeconds = 1200 }),
            };
        }

        return new HttpResponseMessage(HttpStatusCode.NotFound);
    });

    [Fact]
    public void RendersEpisode_WhenLoadSucceeds()
    {
        ConfigureApi(RouteHandler());

        var cut = RenderComponent<EpisodeDetail>(parameters => parameters
            .Add(p => p.ShowId, "show-1")
            .Add(p => p.EpisodeId, "ep-1"));

        cut.WaitForAssertion(() =>
        {
            Assert.Contains("Monday Edition", cut.Markup);
            Assert.Contains("Show notes here", cut.Markup);
        });
    }

    [Fact]
    public void ShowsNotFoundMessage_WhenEpisodeMissing()
    {
        ConfigureApi(TestHttpMessageHandler.Status(HttpStatusCode.NotFound));

        var cut = RenderComponent<EpisodeDetail>(parameters => parameters
            .Add(p => p.ShowId, "show-1")
            .Add(p => p.EpisodeId, "missing"));

        cut.WaitForAssertion(() => Assert.Contains("Episode not found", cut.Markup));
    }

    [Fact]
    public void ShowsErrorMessage_WhenApiRequestFails()
    {
        ConfigureApi(TestHttpMessageHandler.Status(HttpStatusCode.InternalServerError));

        var cut = RenderComponent<EpisodeDetail>(parameters => parameters
            .Add(p => p.ShowId, "show-1")
            .Add(p => p.EpisodeId, "ep-1"));

        cut.WaitForAssertion(() => Assert.Contains("Something went wrong", cut.Markup));
    }

    [Fact]
    public void ShowsNewBadge_WhenNoStateExists()
    {
        ConfigureApi(RouteHandler());

        var cut = RenderComponent<EpisodeDetail>(parameters => parameters
            .Add(p => p.ShowId, "show-1")
            .Add(p => p.EpisodeId, "ep-1"));

        cut.WaitForAssertion(() => Assert.Contains("New", cut.Markup));
    }

    [Fact]
    public void ShowsInProgressBadge_WhenStateHasPartialPosition()
    {
        ConfigureApi(RouteHandler(onGetState: _ =>
            new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(InProgressState) }));

        var cut = RenderComponent<EpisodeDetail>(parameters => parameters
            .Add(p => p.ShowId, "show-1")
            .Add(p => p.EpisodeId, "ep-1"));

        cut.WaitForAssertion(() => Assert.Contains("In progress", cut.Markup));
    }

    [Fact]
    public void MarkAsPlayed_UpdatesBadgeAndButtonLabel()
    {
        ConfigureApi(RouteHandler());

        var cut = RenderComponent<EpisodeDetail>(parameters => parameters
            .Add(p => p.ShowId, "show-1")
            .Add(p => p.EpisodeId, "ep-1"));

        cut.WaitForAssertion(() => Assert.Contains("Mark as played", cut.Markup));

        cut.Find("button.btn-outline-secondary").Click();

        cut.WaitForAssertion(() =>
        {
            Assert.Contains("Played", cut.Markup);
            Assert.Contains("Mark as unplayed", cut.Markup);
        });
    }

    [Fact]
    public void MarkAsUnplayed_PreservesSavedPosition()
    {
        var completedState = InProgressState with { Completed = true, PositionSeconds = 1200 };
        HttpRequestMessage? putRequest = null;
        string? putBody = null;

        ConfigureApi(RouteHandler(
            onGetState: _ => new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(completedState) },
            onPutState: request =>
            {
                putRequest = request;
                putBody = request.Content!.ReadAsStringAsync().GetAwaiter().GetResult();
                return new HttpResponseMessage(HttpStatusCode.OK)
                {
                    Content = JsonContent.Create(completedState with { Completed = false }),
                };
            }));

        var cut = RenderComponent<EpisodeDetail>(parameters => parameters
            .Add(p => p.ShowId, "show-1")
            .Add(p => p.EpisodeId, "ep-1"));

        cut.WaitForAssertion(() => Assert.Contains("Mark as unplayed", cut.Markup));

        cut.Find("button.btn-outline-secondary").Click();

        cut.WaitForAssertion(() =>
        {
            Assert.NotNull(putRequest);
            using var body = JsonDocument.Parse(putBody!);
            Assert.Equal(1200, body.RootElement.GetProperty("positionSeconds").GetInt32());
            Assert.False(body.RootElement.GetProperty("completed").GetBoolean());
        });
    }

    [Fact]
    public void ShowsAutoPlayedBadgeAndRestoreButton_WhenEpisodeWasAutoMarkedPlayed()
    {
        ConfigureApi(RouteHandler(onGetState: _ =>
            new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(AutoPlayedState) }));

        var cut = RenderComponent<EpisodeDetail>(parameters => parameters
            .Add(p => p.ShowId, "show-1")
            .Add(p => p.EpisodeId, "ep-1"));

        cut.WaitForAssertion(() =>
        {
            Assert.Contains("Auto-marked played", cut.Markup);
            Assert.Contains("Restore", cut.Markup);
            Assert.DoesNotContain("Mark as unplayed", cut.Markup);
        });
    }

    [Fact]
    public void Restore_ClearsAutoPlayedAndCompletedState()
    {
        HttpRequestMessage? putRequest = null;
        string? putBody = null;

        ConfigureApi(RouteHandler(
            onGetState: _ => new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(AutoPlayedState) },
            onPutState: request =>
            {
                putRequest = request;
                putBody = request.Content!.ReadAsStringAsync().GetAwaiter().GetResult();
                return new HttpResponseMessage(HttpStatusCode.OK)
                {
                    Content = JsonContent.Create(AutoPlayedState with { Completed = false, AutoPlayed = false, PositionSeconds = 0 }),
                };
            }));

        var cut = RenderComponent<EpisodeDetail>(parameters => parameters
            .Add(p => p.ShowId, "show-1")
            .Add(p => p.EpisodeId, "ep-1"));

        cut.WaitForAssertion(() => Assert.Contains("Restore", cut.Markup));

        cut.Find("button.btn-outline-secondary").Click();

        cut.WaitForAssertion(() =>
        {
            Assert.NotNull(putRequest);
            using var body = JsonDocument.Parse(putBody!);
            Assert.Equal(0, body.RootElement.GetProperty("positionSeconds").GetInt32());
            Assert.False(body.RootElement.GetProperty("completed").GetBoolean());
            Assert.Contains("New", cut.Markup);
            Assert.Contains("Mark as played", cut.Markup);
        });
    }

    [Fact]
    public void StateFetchFailure_DoesNotHideAlreadyLoadedEpisode()
    {
        ConfigureApi(RouteHandler(onGetState: _ => new HttpResponseMessage(HttpStatusCode.InternalServerError)));

        var cut = RenderComponent<EpisodeDetail>(parameters => parameters
            .Add(p => p.ShowId, "show-1")
            .Add(p => p.EpisodeId, "ep-1"));

        cut.WaitForAssertion(() =>
        {
            Assert.Contains("Monday Edition", cut.Markup);
            Assert.DoesNotContain("Something went wrong", cut.Markup);
        });
    }
}
