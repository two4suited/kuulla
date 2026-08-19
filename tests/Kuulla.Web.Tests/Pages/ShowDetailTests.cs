using System.Net;
using System.Net.Http.Json;
using Kuulla.Web.Components.Pages;
using Kuulla.Web.Models;

namespace Kuulla.Web.Tests.Pages;

public class ShowDetailTests : WebTestContext
{
    private static readonly Show TestShow = new(
        "show-1", "The Daily", "NYT", "https://feed", null, "A daily news show", []);

    private static readonly Episode TestEpisode = new(
        "ep-1", "show-1", "Monday Edition", DateTimeOffset.UtcNow, TimeSpan.FromMinutes(20), "https://audio", null, null, null);

    private static readonly Episode OlderEpisode = new(
        "ep-2", "show-1", "Sunday Edition", DateTimeOffset.UtcNow.AddDays(-1), TimeSpan.FromMinutes(20), "https://audio2", null, null, null);

    private static readonly ShowSettings DefaultShowSettings = new("user-1:show-1", "user-1", "show-1", null, Version: 1);

    private TestHttpMessageHandler CreateHandler(
        IReadOnlyList<Subscription>? subscriptions = null,
        ShowSettings? showSettings = null,
        EpisodeState? episodeState = null) =>
        new(request =>
        {
            var path = request.RequestUri!.AbsolutePath;
            if (path == "/api/shows/show-1" && request.Method == HttpMethod.Get)
            {
                return new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(TestShow) };
            }

            if (path == "/api/shows/show-1/episodes" && request.Method == HttpMethod.Get)
            {
                var page = new EpisodePage([TestEpisode], null);
                return new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(page) };
            }

            if (path == "/api/episodes/states" && request.Method == HttpMethod.Post)
            {
                var states = episodeState is null
                    ? new Dictionary<string, EpisodeState>()
                    : new Dictionary<string, EpisodeState> { ["ep-1"] = episodeState };
                return new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(states) };
            }

            if (path == "/api/episodes/ep-1/state" && request.Method == HttpMethod.Put)
            {
                return new HttpResponseMessage(HttpStatusCode.OK)
                {
                    Content = JsonContent.Create(new EpisodeState("ep-1", "user-1", "ep-1", "show-1", 0, false, DateTimeOffset.UtcNow, "web", AutoPlayed: false)),
                };
            }

            if (path == "/api/subscriptions" && request.Method == HttpMethod.Get)
            {
                return new HttpResponseMessage(HttpStatusCode.OK)
                {
                    Content = JsonContent.Create(subscriptions ?? []),
                };
            }

            if (path == "/api/subscriptions" && request.Method == HttpMethod.Post)
            {
                var subscription = new Subscription("sub-1", "show-1", "The Daily", "NYT", null, DateTimeOffset.UtcNow);
                return new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(subscription) };
            }

            if (path == "/api/subscriptions/show-1" && request.Method == HttpMethod.Delete)
            {
                return new HttpResponseMessage(HttpStatusCode.OK);
            }

            if (path == "/api/settings/shows/show-1" && request.Method == HttpMethod.Get)
            {
                return new HttpResponseMessage(HttpStatusCode.OK)
                {
                    Content = JsonContent.Create(showSettings ?? DefaultShowSettings),
                };
            }

            if (path == "/api/settings/shows/show-1" && request.Method == HttpMethod.Put)
            {
                return new HttpResponseMessage(HttpStatusCode.OK)
                {
                    Content = JsonContent.Create(showSettings ?? DefaultShowSettings),
                };
            }

            return new HttpResponseMessage(HttpStatusCode.NotFound);
        });

    private TestHttpMessageHandler CreateHandlerWithEpisodes(
        IReadOnlyList<Episode> episodes, IReadOnlyDictionary<string, EpisodeState> states) =>
        new(request =>
        {
            var path = request.RequestUri!.AbsolutePath;
            if (path == "/api/shows/show-1" && request.Method == HttpMethod.Get)
            {
                return new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(TestShow) };
            }

            if (path == "/api/shows/show-1/episodes" && request.Method == HttpMethod.Get)
            {
                return new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(new EpisodePage(episodes, null)) };
            }

            if (path == "/api/episodes/states" && request.Method == HttpMethod.Post)
            {
                return new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(states) };
            }

            if (path == "/api/subscriptions" && request.Method == HttpMethod.Get)
            {
                return new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(new List<Subscription>()) };
            }

            if (path == "/api/settings/shows/show-1" && request.Method == HttpMethod.Get)
            {
                return new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(DefaultShowSettings) };
            }

            return new HttpResponseMessage(HttpStatusCode.NotFound);
        });

    [Fact]
    public void RendersShowAndEpisodes_WhenLoadSucceeds()
    {
        ConfigureApi(CreateHandler());

        var cut = RenderComponent<ShowDetail>(parameters => parameters.Add(p => p.Id, "show-1"));

        cut.WaitForAssertion(() =>
        {
            Assert.Contains("The Daily", cut.Markup);
            Assert.Contains("Monday Edition", cut.Markup);
        });
    }

    [Fact]
    public void ShowsNotFoundMessage_WhenShowMissing()
    {
        ConfigureApi(new TestHttpMessageHandler(_ => new HttpResponseMessage(HttpStatusCode.NotFound)));

        var cut = RenderComponent<ShowDetail>(parameters => parameters.Add(p => p.Id, "missing"));

        cut.WaitForAssertion(() => Assert.Contains("Show not found", cut.Markup));
    }

    [Fact]
    public void SubscribeButton_IsHidden_WhenNotAuthenticated()
    {
        ConfigureApi(CreateHandler());

        var cut = RenderComponent<ShowDetail>(parameters => parameters.Add(p => p.Id, "show-1"));

        cut.WaitForAssertion(() => Assert.Contains("The Daily", cut.Markup));
        Assert.DoesNotContain("Subscribe", cut.Markup);
    }

    [Fact]
    public void SubscribesToShow_WhenSubscribeClicked()
    {
        AuthContext.SetAuthorized("test-user");
        ConfigureApi(CreateHandler());

        var cut = RenderComponent<ShowDetail>(parameters => parameters.Add(p => p.Id, "show-1"));
        cut.WaitForAssertion(() => Assert.Contains("Subscribe", cut.Markup));

        cut.Find("button.btn-primary").Click();

        cut.WaitForAssertion(() =>
        {
            Assert.Contains("Unsubscribe", cut.Markup);
            Assert.DoesNotContain("Something went wrong", cut.Markup);
        });
    }

    [Fact]
    public void SettingsSelector_IsHidden_WhenNotAuthenticated()
    {
        ConfigureApi(CreateHandler());

        var cut = RenderComponent<ShowDetail>(parameters => parameters.Add(p => p.Id, "show-1"));

        cut.WaitForAssertion(() => Assert.Contains("The Daily", cut.Markup));
        Assert.DoesNotContain("Unlistened episodes to show", cut.Markup);
    }

    [Fact]
    public void SettingsSelector_DefaultsToUseGlobalDefault_WhenNoOverrideExists()
    {
        AuthContext.SetAuthorized("user-1");
        ConfigureApi(CreateHandler());

        var cut = RenderComponent<ShowDetail>(parameters => parameters.Add(p => p.Id, "show-1"));

        cut.WaitForAssertion(() => Assert.Equal("", cut.Find("#show-unlistened-episode-count").GetAttribute("value")));
    }

    [Fact]
    public void SettingsSelector_ShowsExistingOverride()
    {
        AuthContext.SetAuthorized("user-1");
        var existing = new ShowSettings("user-1:show-1", "user-1", "show-1", UnlistenedEpisodeCount.Ten, Version: 2);
        ConfigureApi(CreateHandler(showSettings: existing));

        var cut = RenderComponent<ShowDetail>(parameters => parameters.Add(p => p.Id, "show-1"));

        cut.WaitForAssertion(() => Assert.Equal("Ten", cut.Find("#show-unlistened-episode-count").GetAttribute("value")));
    }

    [Fact]
    public void SettingsSelector_SavesOverride_WhenChanged()
    {
        AuthContext.SetAuthorized("user-1");
        ConfigureApi(CreateHandler(showSettings: new("user-1:show-1", "user-1", "show-1", UnlistenedEpisodeCount.Two, Version: 2)));

        var cut = RenderComponent<ShowDetail>(parameters => parameters.Add(p => p.Id, "show-1"));
        cut.WaitForAssertion(() => Assert.Contains("Unlistened episodes to show", cut.Markup));

        cut.Find("#show-unlistened-episode-count").Change("Two");

        cut.WaitForAssertion(() => Assert.Contains("Saved.", cut.Markup));
    }

    [Fact]
    public void SettingsSelector_ShowsErrorMessage_WhenLoadFails()
    {
        AuthContext.SetAuthorized("user-1");
        ConfigureApi(new TestHttpMessageHandler(request =>
        {
            var path = request.RequestUri!.AbsolutePath;
            if (path == "/api/settings/shows/show-1" && request.Method == HttpMethod.Get)
            {
                return new HttpResponseMessage(HttpStatusCode.InternalServerError);
            }

            if (path == "/api/shows/show-1" && request.Method == HttpMethod.Get)
            {
                return new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(TestShow) };
            }

            if (path == "/api/shows/show-1/episodes" && request.Method == HttpMethod.Get)
            {
                return new HttpResponseMessage(HttpStatusCode.OK)
                {
                    Content = JsonContent.Create(new EpisodePage([TestEpisode], null)),
                };
            }

            if (path == "/api/subscriptions" && request.Method == HttpMethod.Get)
            {
                return new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(new List<Subscription>()) };
            }

            if (path == "/api/episodes/states" && request.Method == HttpMethod.Post)
            {
                return new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(new Dictionary<string, EpisodeState>()) };
            }

            return new HttpResponseMessage(HttpStatusCode.NotFound);
        }));

        var cut = RenderComponent<ShowDetail>(parameters => parameters.Add(p => p.Id, "show-1"));

        cut.WaitForAssertion(() => Assert.Contains("Something went wrong while loading this show's settings", cut.Markup));
    }

    [Fact]
    public void ShowsAutoPlayedIndicatorAndRestoreButton_ForAutoPlayedEpisode()
    {
        AuthContext.SetAuthorized("user-1");
        var autoPlayedState = new EpisodeState("ep-1", "user-1", "ep-1", "show-1", 0, true, DateTimeOffset.UtcNow, null, AutoPlayed: true);
        ConfigureApi(CreateHandler(episodeState: autoPlayedState));

        var cut = RenderComponent<ShowDetail>(parameters => parameters.Add(p => p.Id, "show-1"));

        cut.WaitForAssertion(() =>
        {
            Assert.Contains("Auto-marked played", cut.Markup);
            Assert.Contains("Restore", cut.Markup);
        });
    }

    [Fact]
    public void NoAutoPlayedIndicator_ForOrdinaryEpisode()
    {
        AuthContext.SetAuthorized("user-1");
        ConfigureApi(CreateHandler());

        var cut = RenderComponent<ShowDetail>(parameters => parameters.Add(p => p.Id, "show-1"));

        cut.WaitForAssertion(() => Assert.Contains("Monday Edition", cut.Markup));
        Assert.DoesNotContain("Auto-marked played", cut.Markup);
    }

    [Fact]
    public void RestoringAutoPlayedEpisode_ClearsIndicator()
    {
        AuthContext.SetAuthorized("user-1");
        var autoPlayedState = new EpisodeState("ep-1", "user-1", "ep-1", "show-1", 0, true, DateTimeOffset.UtcNow, null, AutoPlayed: true);
        ConfigureApi(CreateHandler(episodeState: autoPlayedState));

        var cut = RenderComponent<ShowDetail>(parameters => parameters.Add(p => p.Id, "show-1"));
        cut.WaitForAssertion(() => Assert.Contains("Auto-marked played", cut.Markup));

        cut.Find("li button.btn-outline-secondary").Click();

        cut.WaitForAssertion(() => Assert.DoesNotContain("Auto-marked played", cut.Markup));
    }

    [Fact]
    public void UnplayedFilter_HidesInProgressAndPlayedEpisodes()
    {
        AuthContext.SetAuthorized("user-1");
        var inProgressState = new EpisodeState("s1", "user-1", "ep-1", "show-1", 300, false, DateTimeOffset.UtcNow, "web");
        ConfigureApi(CreateHandlerWithEpisodes(
            [TestEpisode, OlderEpisode],
            new Dictionary<string, EpisodeState> { ["ep-1"] = inProgressState }));

        var cut = RenderComponent<ShowDetail>(parameters => parameters.Add(p => p.Id, "show-1"));
        cut.WaitForAssertion(() =>
        {
            Assert.Contains("Monday Edition", cut.Markup);
            Assert.Contains("Sunday Edition", cut.Markup);
        });

        cut.FindAll(".btn-group button").Single(b => b.TextContent.Trim() == "Unplayed").Click();

        cut.WaitForAssertion(() =>
        {
            Assert.DoesNotContain("Monday Edition", cut.Markup);
            Assert.Contains("Sunday Edition", cut.Markup);
        });
    }

    [Fact]
    public void InProgressFilter_ShowsOnlyInProgressEpisodes()
    {
        AuthContext.SetAuthorized("user-1");
        var inProgressState = new EpisodeState("s1", "user-1", "ep-1", "show-1", 300, false, DateTimeOffset.UtcNow, "web");
        ConfigureApi(CreateHandlerWithEpisodes(
            [TestEpisode, OlderEpisode],
            new Dictionary<string, EpisodeState> { ["ep-1"] = inProgressState }));

        var cut = RenderComponent<ShowDetail>(parameters => parameters.Add(p => p.Id, "show-1"));
        cut.WaitForAssertion(() => Assert.Contains("Sunday Edition", cut.Markup));

        cut.FindAll(".btn-group button").Single(b => b.TextContent.Trim() == "In Progress").Click();

        cut.WaitForAssertion(() =>
        {
            Assert.Contains("Monday Edition", cut.Markup);
            Assert.DoesNotContain("Sunday Edition", cut.Markup);
        });
    }

    [Fact]
    public void SortControl_ReversesEpisodeOrder_WhenOldestFirstSelected()
    {
        ConfigureApi(CreateHandlerWithEpisodes([TestEpisode, OlderEpisode], new Dictionary<string, EpisodeState>()));

        var cut = RenderComponent<ShowDetail>(parameters => parameters.Add(p => p.Id, "show-1"));
        cut.WaitForAssertion(() =>
            Assert.True(cut.Markup.IndexOf("Monday Edition", StringComparison.Ordinal)
                < cut.Markup.IndexOf("Sunday Edition", StringComparison.Ordinal)));

        cut.Find("select.form-select-sm").Change("OldestFirst");

        cut.WaitForAssertion(() =>
            Assert.True(cut.Markup.IndexOf("Sunday Edition", StringComparison.Ordinal)
                < cut.Markup.IndexOf("Monday Edition", StringComparison.Ordinal)));
    }

    [Fact]
    public void ShowsProgressBar_ForInProgressEpisode()
    {
        AuthContext.SetAuthorized("user-1");
        var inProgressState = new EpisodeState("s1", "user-1", "ep-1", "show-1", 300, false, DateTimeOffset.UtcNow, "web");
        ConfigureApi(CreateHandler(episodeState: inProgressState));

        var cut = RenderComponent<ShowDetail>(parameters => parameters.Add(p => p.Id, "show-1"));

        cut.WaitForAssertion(() => Assert.Contains("progress-bar", cut.Markup));
    }

    [Fact]
    public void ShowsPlayedBadge_ForCompletedNonAutoPlayedEpisode()
    {
        AuthContext.SetAuthorized("user-1");
        var playedState = new EpisodeState("s1", "user-1", "ep-1", "show-1", 1200, true, DateTimeOffset.UtcNow, "web", AutoPlayed: false);
        ConfigureApi(CreateHandler(episodeState: playedState));

        var cut = RenderComponent<ShowDetail>(parameters => parameters.Add(p => p.Id, "show-1"));

        cut.WaitForAssertion(() =>
        {
            Assert.Contains("Played", cut.Markup);
            Assert.DoesNotContain("Auto-marked played", cut.Markup);
        });
    }
}
