using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
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

    private static readonly UserSettings DefaultGlobalSettings = new("user-1", UnlistenedEpisodeCount.Five, Version: 1);

    private TestHttpMessageHandler CreateHandler(
        IReadOnlyList<Subscription>? subscriptions = null,
        ShowSettings? showSettings = null,
        EpisodeState? episodeState = null,
        ShowSettings? autoDownloadPutResponse = null,
        ShowSettings? autoAddUpNextPutResponse = null,
        UserSettings? globalSettings = null,
        ShowSettings? upNextInsertPositionPutResponse = null,
        ShowSettings? playNextPutResponse = null) =>
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
                bool completed;
                if (request.Content is null)
                {
                    completed = false;
                }
                else
                {
                    using var payload = JsonDocument.Parse(request.Content.ReadAsStringAsync().GetAwaiter().GetResult());
                    completed = payload.RootElement.TryGetProperty("completed", out var completedProperty)
                        && completedProperty.GetBoolean();
                }

                var positionSeconds = completed ? 1200 : 0;
                return new HttpResponseMessage(HttpStatusCode.OK)
                {
                    Content = JsonContent.Create(new EpisodeState("ep-1", "user-1", "ep-1", "show-1", positionSeconds, completed, DateTimeOffset.UtcNow, "web", AutoPlayed: false)),
                };
            }

            if (path == "/api/shows/show-1/episode-state/mark-all-played" && request.Method == HttpMethod.Post)
            {
                var markedState = new EpisodeState(
                    "ep-1", "user-1", "ep-1", "show-1", 1200, true, DateTimeOffset.UtcNow, "web", AutoPlayed: false);
                return new HttpResponseMessage(HttpStatusCode.OK)
                {
                    Content = JsonContent.Create(new MarkAllPlayedResult(1, 1, [markedState])),
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

            if (path == "/api/settings/shows/show-1/auto-archive" && request.Method == HttpMethod.Put)
            {
                return new HttpResponseMessage(HttpStatusCode.OK)
                {
                    Content = JsonContent.Create(showSettings ?? DefaultShowSettings),
                };
            }

            if (path == "/api/settings/shows/show-1/auto-download" && request.Method == HttpMethod.Put)
            {
                return new HttpResponseMessage(HttpStatusCode.OK)
                {
                    Content = JsonContent.Create(autoDownloadPutResponse ?? showSettings ?? DefaultShowSettings),
                };
            }

            if (path == "/api/settings/shows/show-1/auto-add-up-next" && request.Method == HttpMethod.Put)
            {
                return new HttpResponseMessage(HttpStatusCode.OK)
                {
                    Content = JsonContent.Create(autoAddUpNextPutResponse ?? showSettings ?? DefaultShowSettings),
                };
            }

            if (path == "/api/settings/shows/show-1/up-next-insert-position" && request.Method == HttpMethod.Put)
            {
                return new HttpResponseMessage(HttpStatusCode.OK)
                {
                    Content = JsonContent.Create(upNextInsertPositionPutResponse ?? showSettings ?? DefaultShowSettings),
                };
            }

            if (path == "/api/settings/shows/show-1/play-next" && request.Method == HttpMethod.Put)
            {
                return new HttpResponseMessage(HttpStatusCode.OK)
                {
                    Content = JsonContent.Create(playNextPutResponse ?? showSettings ?? DefaultShowSettings),
                };
            }

            if (path == "/api/settings" && request.Method == HttpMethod.Get)
            {
                return new HttpResponseMessage(HttpStatusCode.OK)
                {
                    Content = JsonContent.Create(globalSettings ?? DefaultGlobalSettings),
                };
            }

            if ((path == "/api/settings/shows/show-1/auto-skip"
                 || path == "/api/settings/shows/show-1/playback-speed"
                 || path == "/api/settings/shows/show-1/smart-speed"
                 || path == "/api/settings/shows/show-1/notifications"
                 || path == "/api/settings/shows/show-1/auto-delete")
                && request.Method == HttpMethod.Put)
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

    // The per-show settings now live behind a gear popover (issue #500) instead of rendering
    // inline, so any test that touches a #show-* control has to open it first.
    private static void OpenShowSettings(IRenderedComponent<ShowDetail> cut)
        => cut.WaitForElement("button[aria-label='Podcast settings']").Click();

    // Every per-show control is now a SegmentedChoice / RadioChoice / stepper / slider keyed by
    // the same #show-* id the old <select> used (issue #504). These helpers pick a labelled
    // button inside one and report which one is selected.
    // RadioChoice prefixes the selected row with a "✓" text node; strip it so callers match on
    // the plain label.
    private static string ChoiceLabel(AngleSharp.Dom.IElement button)
        => button.TextContent.Replace("✓", "").Trim();

    private static AngleSharp.Dom.IElement Choice(IRenderedComponent<ShowDetail> cut, string id, string label)
        => cut.FindAll($"#{id} button").Single(b => ChoiceLabel(b) == label);

    private static string SelectedChoice(IRenderedComponent<ShowDetail> cut, string id)
        => ChoiceLabel(cut.FindAll($"#{id} button")
            .Single(b => b.GetAttribute("aria-pressed") == "true" || b.GetAttribute("aria-checked") == "true"));

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
    public void ShowsManualMarkAsPlayedButton_FromEpisodeList()
    {
        AuthContext.SetAuthorized("user-1");
        ConfigureApi(CreateHandler());

        var cut = RenderComponent<ShowDetail>(parameters => parameters.Add(p => p.Id, "show-1"));

        cut.WaitForAssertion(() => Assert.Contains("Mark as played", cut.Markup));
        cut.FindAll(".btn-group button").Single(b => b.TextContent.Trim() == "All").Click();
        cut.WaitForAssertion(() => Assert.Contains("Mark as played", cut.Markup));

        cut.FindAll("button.btn-outline-secondary").Single(b => b.TextContent.Trim() == "Mark as played").Click();

        cut.WaitForAssertion(() =>
        {
            Assert.Contains("Mark as unplayed", cut.Markup);
            Assert.Contains("Played", cut.Markup);
        });
    }

    [Fact]
    public void MarkAllPlayedButton_IsHidden_WhenNotAuthenticated()
    {
        ConfigureApi(CreateHandler());

        var cut = RenderComponent<ShowDetail>(parameters => parameters.Add(p => p.Id, "show-1"));

        cut.WaitForAssertion(() => Assert.Contains("The Daily", cut.Markup));
        Assert.DoesNotContain("Mark all played", cut.Markup);
    }

    [Fact]
    public void MarkAllPlayed_MarksLoadedEpisodesPlayed_AfterConfirmation()
    {
        AuthContext.SetAuthorized("user-1");
        ConfigureApi(CreateHandler());

        var cut = RenderComponent<ShowDetail>(parameters => parameters.Add(p => p.Id, "show-1"));
        cut.WaitForAssertion(() => Assert.Contains("Monday Edition", cut.Markup));

        cut.FindAll("button").Single(b => b.TextContent.Trim() == "Mark all played").Click();
        cut.WaitForAssertion(() => Assert.Contains("Mark every episode of this show as played?", cut.Markup));

        cut.FindAll("button").Single(b => b.TextContent.Trim() == "Yes, mark all played").Click();

        cut.WaitForAssertion(() =>
        {
            // Default filter is "Unfinished", which hides played episodes — the marked episode drops out.
            Assert.DoesNotContain("Mark every episode of this show as played?", cut.Markup);
            Assert.DoesNotContain("Monday Edition", cut.Markup);
        });

        cut.FindAll(".btn-group button").Single(b => b.TextContent.Trim() == "All").Click();
        cut.WaitForAssertion(() =>
        {
            Assert.Contains("Monday Edition", cut.Markup);
            Assert.Contains("Played", cut.Markup);
        });
    }

    [Fact]
    public void MarkAllPlayed_ShowsError_WhenRequestFails()
    {
        AuthContext.SetAuthorized("user-1");
        ConfigureApi(new TestHttpMessageHandler(request =>
        {
            var path = request.RequestUri!.AbsolutePath;
            if (path == "/api/shows/show-1/episode-state/mark-all-played" && request.Method == HttpMethod.Post)
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

            if (path == "/api/episodes/states" && request.Method == HttpMethod.Post)
            {
                return new HttpResponseMessage(HttpStatusCode.OK)
                {
                    Content = JsonContent.Create(new Dictionary<string, EpisodeState>()),
                };
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
        }));

        var cut = RenderComponent<ShowDetail>(parameters => parameters.Add(p => p.Id, "show-1"));
        cut.WaitForAssertion(() => Assert.Contains("Mark all played", cut.Markup));

        cut.FindAll("button").Single(b => b.TextContent.Trim() == "Mark all played").Click();
        cut.FindAll("button").Single(b => b.TextContent.Trim() == "Yes, mark all played").Click();

        cut.WaitForAssertion(() => Assert.Contains("Something went wrong while marking episodes played", cut.Markup));
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
        OpenShowSettings(cut);

        cut.WaitForAssertion(() => Assert.Equal("Default", SelectedChoice(cut, "show-unlistened-episode-count")));
    }

    [Fact]
    public void SettingsSelector_ShowsExistingOverride()
    {
        AuthContext.SetAuthorized("user-1");
        var existing = new ShowSettings("user-1:show-1", "user-1", "show-1", UnlistenedEpisodeCount.Ten, Version: 2);
        ConfigureApi(CreateHandler(showSettings: existing));

        var cut = RenderComponent<ShowDetail>(parameters => parameters.Add(p => p.Id, "show-1"));
        OpenShowSettings(cut);

        cut.WaitForAssertion(() => Assert.Equal("10", SelectedChoice(cut, "show-unlistened-episode-count")));
    }

    [Fact]
    public void SettingsSelector_SavesOverride_WhenChanged()
    {
        AuthContext.SetAuthorized("user-1");
        ConfigureApi(CreateHandler(showSettings: new("user-1:show-1", "user-1", "show-1", UnlistenedEpisodeCount.Two, Version: 2)));

        var cut = RenderComponent<ShowDetail>(parameters => parameters.Add(p => p.Id, "show-1"));
        OpenShowSettings(cut);
        cut.WaitForAssertion(() => Assert.Equal("2", SelectedChoice(cut, "show-unlistened-episode-count")));

        Choice(cut, "show-unlistened-episode-count", "5").Click();

        cut.WaitForAssertion(() => Assert.Contains("Saved.", cut.Markup));
    }

    [Fact]
    public void ArchiveSelector_DefaultsToUseGlobalDefault_WhenNoOverrideExists()
    {
        AuthContext.SetAuthorized("user-1");
        ConfigureApi(CreateHandler());

        var cut = RenderComponent<ShowDetail>(parameters => parameters.Add(p => p.Id, "show-1"));
        OpenShowSettings(cut);

        cut.WaitForAssertion(() => Assert.Equal("Use global default", SelectedChoice(cut, "show-auto-archive-rule")));
    }

    [Fact]
    public void ArchiveSelector_ShowsExistingOverride()
    {
        AuthContext.SetAuthorized("user-1");
        var existing = new ShowSettings("user-1:show-1", "user-1", "show-1", null, Version: 2, AutoArchiveRule.After30Days);
        ConfigureApi(CreateHandler(showSettings: existing));

        var cut = RenderComponent<ShowDetail>(parameters => parameters.Add(p => p.Id, "show-1"));
        OpenShowSettings(cut);

        cut.WaitForAssertion(() => Assert.Equal("30 days after played", SelectedChoice(cut, "show-auto-archive-rule")));
    }

    [Fact]
    public void ArchiveSelector_SavesOverride_WhenChanged()
    {
        AuthContext.SetAuthorized("user-1");
        ConfigureApi(CreateHandler(showSettings: new("user-1:show-1", "user-1", "show-1", null, Version: 2, AutoArchiveRule.AfterPlayed)));

        var cut = RenderComponent<ShowDetail>(parameters => parameters.Add(p => p.Id, "show-1"));
        OpenShowSettings(cut);
        cut.WaitForAssertion(() => Assert.Equal("Immediately after played", SelectedChoice(cut, "show-auto-archive-rule")));

        Choice(cut, "show-auto-archive-rule", "Never").Click();

        cut.WaitForAssertion(() => Assert.Contains("Saved.", cut.Markup));
    }

    [Fact]
    public void AutoDownloadSelector_DefaultsToUseGlobalDefault_WhenNoOverrideExists()
    {
        AuthContext.SetAuthorized("user-1");
        ConfigureApi(CreateHandler());

        var cut = RenderComponent<ShowDetail>(parameters => parameters.Add(p => p.Id, "show-1"));
        OpenShowSettings(cut);

        cut.WaitForAssertion(() => Assert.Equal("Default", SelectedChoice(cut, "show-auto-download-new-episodes")));
    }

    [Fact]
    public void AutoDownloadSelector_ShowsExistingOverride()
    {
        AuthContext.SetAuthorized("user-1");
        var existing = new ShowSettings("user-1:show-1", "user-1", "show-1", null, Version: 2, AutoDownloadNewEpisodes: true);
        ConfigureApi(CreateHandler(showSettings: existing));

        var cut = RenderComponent<ShowDetail>(parameters => parameters.Add(p => p.Id, "show-1"));
        OpenShowSettings(cut);

        cut.WaitForAssertion(() => Assert.Equal("On", SelectedChoice(cut, "show-auto-download-new-episodes")));
    }

    [Fact]
    public void AutoDownloadSelector_SavesOverride_WhenChanged()
    {
        AuthContext.SetAuthorized("user-1");
        ConfigureApi(CreateHandler(showSettings: new("user-1:show-1", "user-1", "show-1", null, Version: 2, AutoDownloadNewEpisodes: true)));

        var cut = RenderComponent<ShowDetail>(parameters => parameters.Add(p => p.Id, "show-1"));
        OpenShowSettings(cut);
        cut.WaitForAssertion(() => Assert.Equal("On", SelectedChoice(cut, "show-auto-download-new-episodes")));

        Choice(cut, "show-auto-download-new-episodes", "Off").Click();

        cut.WaitForAssertion(() => Assert.Contains("Saved.", cut.Markup));
    }

    [Fact]
    public void AutoDeleteSelector_DefaultsToUseGlobalDefault_WhenNoOverrideExists()
    {
        AuthContext.SetAuthorized("user-1");
        ConfigureApi(CreateHandler());

        var cut = RenderComponent<ShowDetail>(parameters => parameters.Add(p => p.Id, "show-1"));
        OpenShowSettings(cut);

        cut.WaitForAssertion(() => Assert.Equal("Use global default", SelectedChoice(cut, "show-auto-delete-rule")));
    }

    [Fact]
    public void AutoDeleteSelector_ShowsExistingOverride_WithAfterDaysInput()
    {
        AuthContext.SetAuthorized("user-1");
        var existing = new ShowSettings(
            "user-1:show-1", "user-1", "show-1", null, Version: 2,
            AutoDeleteRule: AutoDeleteRule.AfterDays, AutoDeleteAfterDays: 14);
        ConfigureApi(CreateHandler(showSettings: existing));

        var cut = RenderComponent<ShowDetail>(parameters => parameters.Add(p => p.Id, "show-1"));
        OpenShowSettings(cut);

        cut.WaitForAssertion(() => Assert.Equal("After N days", SelectedChoice(cut, "show-auto-delete-rule")));
        cut.WaitForAssertion(() => Assert.Equal("14", cut.Find("#show-auto-delete-after-days").GetAttribute("value")));
    }

    [Fact]
    public void AutoDeleteSelector_SavesOverride_WhenChanged()
    {
        AuthContext.SetAuthorized("user-1");
        ConfigureApi(CreateHandler());

        var cut = RenderComponent<ShowDetail>(parameters => parameters.Add(p => p.Id, "show-1"));
        OpenShowSettings(cut);
        cut.WaitForAssertion(() => Assert.Contains("Delete downloads", cut.Markup));

        Choice(cut, "show-auto-delete-rule", "After played").Click();

        cut.WaitForAssertion(() => Assert.Contains("Saved.", cut.Markup));
    }

    [Fact]
    public void AutoAddUpNextSelector_ShowsExistingOverride()
    {
        AuthContext.SetAuthorized("user-1");
        var existing = new ShowSettings("user-1:show-1", "user-1", "show-1", null, Version: 2, AutoAddNewEpisodesToUpNext: false);
        ConfigureApi(CreateHandler(showSettings: existing));

        var cut = RenderComponent<ShowDetail>(parameters => parameters.Add(p => p.Id, "show-1"));
        OpenShowSettings(cut);

        cut.WaitForAssertion(() => Assert.Equal("Off", SelectedChoice(cut, "show-auto-add-up-next")));
    }

    [Fact]
    public void AutoAddUpNextSelector_SavesOverride_WhenChanged()
    {
        AuthContext.SetAuthorized("user-1");
        ConfigureApi(CreateHandler(
            autoAddUpNextPutResponse: new("user-1:show-1", "user-1", "show-1", null, Version: 3, AutoAddNewEpisodesToUpNext: true)));

        var cut = RenderComponent<ShowDetail>(parameters => parameters.Add(p => p.Id, "show-1"));
        OpenShowSettings(cut);
        cut.WaitForAssertion(() => Assert.Contains("Add new episodes to Up Next", cut.Markup));

        Choice(cut, "show-auto-add-up-next", "On").Click();

        cut.WaitForAssertion(() => Assert.Contains("Saved.", cut.Markup));
    }

    [Fact]
    public void PlayNextSelector_RendersOverride_WhenSet()
    {
        AuthContext.SetAuthorized("user-1");
        var existing = new ShowSettings(
            "user-1:show-1", "user-1", "show-1", null, Version: 2, PlayNextBehavior: PlayNextBehavior.Stop);
        ConfigureApi(CreateHandler(showSettings: existing));

        var cut = RenderComponent<ShowDetail>(parameters => parameters.Add(p => p.Id, "show-1"));
        OpenShowSettings(cut);

        cut.WaitForAssertion(() => Assert.Equal("Stop", SelectedChoice(cut, "show-play-next")));
    }

    [Fact]
    public void PlayNextSelector_DefaultsToUseGlobalDefault_AndSavesOverride()
    {
        AuthContext.SetAuthorized("user-1");
        ConfigureApi(CreateHandler(
            playNextPutResponse: new(
                "user-1:show-1", "user-1", "show-1", null, Version: 3, PlayNextBehavior: PlayNextBehavior.TopOfList)));

        var cut = RenderComponent<ShowDetail>(parameters => parameters.Add(p => p.Id, "show-1"));
        OpenShowSettings(cut);
        cut.WaitForAssertion(() => Assert.Equal("Use global default", SelectedChoice(cut, "show-play-next")));

        Choice(cut, "show-play-next", "Play from the top of the list").Click();

        cut.WaitForAssertion(() =>
        {
            Assert.Contains("Saved.", cut.Markup);
            Assert.Equal("Play from the top of the list", SelectedChoice(cut, "show-play-next"));
        });
    }

    [Fact]
    public void UpNextInsertPositionSelector_Hidden_WhenEffectiveAutoAddIsOff()
    {
        AuthContext.SetAuthorized("user-1");
        ConfigureApi(CreateHandler());

        var cut = RenderComponent<ShowDetail>(parameters => parameters.Add(p => p.Id, "show-1"));
        OpenShowSettings(cut);
        cut.WaitForAssertion(() => Assert.Contains("Add new episodes to Up Next", cut.Markup));

        Assert.Empty(cut.FindAll("#show-up-next-insert-position"));
    }

    [Fact]
    public void UpNextInsertPositionSelector_ShownWithOverride_WhenGlobalAutoAddIsOn()
    {
        AuthContext.SetAuthorized("user-1");
        var existing = new ShowSettings(
            "user-1:show-1", "user-1", "show-1", null, Version: 2, UpNextInsertPosition: UpNextInsertPosition.Top);
        ConfigureApi(CreateHandler(
            showSettings: existing,
            globalSettings: new("user-1", UnlistenedEpisodeCount.Five, Version: 1, AutoAddNewEpisodesToUpNext: true)));

        var cut = RenderComponent<ShowDetail>(parameters => parameters.Add(p => p.Id, "show-1"));
        OpenShowSettings(cut);

        cut.WaitForAssertion(
            () => Assert.Equal("Top of the queue", SelectedChoice(cut, "show-up-next-insert-position")));
    }

    [Fact]
    public void UpNextInsertPositionSelector_ShownWhenShowAutoAddOverrideOn_AndSavesOverride()
    {
        AuthContext.SetAuthorized("user-1");
        var existing = new ShowSettings(
            "user-1:show-1", "user-1", "show-1", null, Version: 2, AutoAddNewEpisodesToUpNext: true);
        ConfigureApi(CreateHandler(
            showSettings: existing,
            upNextInsertPositionPutResponse: new(
                "user-1:show-1", "user-1", "show-1", null, Version: 3,
                AutoAddNewEpisodesToUpNext: true, UpNextInsertPosition: UpNextInsertPosition.Top)));

        var cut = RenderComponent<ShowDetail>(parameters => parameters.Add(p => p.Id, "show-1"));
        OpenShowSettings(cut);
        cut.WaitForAssertion(() => Assert.NotEmpty(cut.FindAll("#show-up-next-insert-position")));

        Choice(cut, "show-up-next-insert-position", "Top of the queue").Click();

        cut.WaitForAssertion(() => Assert.Contains("Saved.", cut.Markup));
    }

    [Fact]
    public void AutoDownloadSelector_SavesUseGlobalDefault_WhenClearedBackToNull()
    {
        AuthContext.SetAuthorized("user-1");
        var existing = new ShowSettings("user-1:show-1", "user-1", "show-1", null, Version: 2, AutoDownloadNewEpisodes: true);
        ConfigureApi(CreateHandler(
            showSettings: existing,
            autoDownloadPutResponse: new("user-1:show-1", "user-1", "show-1", null, Version: 3, AutoDownloadNewEpisodes: null)));

        var cut = RenderComponent<ShowDetail>(parameters => parameters.Add(p => p.Id, "show-1"));
        OpenShowSettings(cut);
        cut.WaitForAssertion(() => Assert.Equal("On", SelectedChoice(cut, "show-auto-download-new-episodes")));

        Choice(cut, "show-auto-download-new-episodes", "Default").Click();

        cut.WaitForAssertion(() =>
        {
            Assert.Contains("Saved.", cut.Markup);
            Assert.Equal("Default", SelectedChoice(cut, "show-auto-download-new-episodes"));
        });
    }

    [Fact]
    public void AutoDownloadSelector_ShowsErrorAndReverts_WhenSaveFails()
    {
        AuthContext.SetAuthorized("user-1");
        ConfigureApi(new TestHttpMessageHandler(request =>
        {
            var path = request.RequestUri!.AbsolutePath;
            if (path == "/api/settings/shows/show-1/auto-download" && request.Method == HttpMethod.Put)
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

            if (path == "/api/episodes/states" && request.Method == HttpMethod.Post)
            {
                return new HttpResponseMessage(HttpStatusCode.OK)
                {
                    Content = JsonContent.Create(new Dictionary<string, EpisodeState>()),
                };
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
        }));

        var cut = RenderComponent<ShowDetail>(parameters => parameters.Add(p => p.Id, "show-1"));
        OpenShowSettings(cut);
        cut.WaitForAssertion(() => Assert.Equal("Default", SelectedChoice(cut, "show-auto-download-new-episodes")));

        Choice(cut, "show-auto-download-new-episodes", "On").Click();

        cut.WaitForAssertion(() =>
        {
            Assert.Contains("Something went wrong", cut.Markup);
            Assert.Equal("Default", SelectedChoice(cut, "show-auto-download-new-episodes"));
        });
    }

    [Fact]
    public void AutoSkipSelectors_DefaultToUseGlobalDefault_WhenNoOverrideExists()
    {
        AuthContext.SetAuthorized("user-1");
        ConfigureApi(CreateHandler());

        var cut = RenderComponent<ShowDetail>(parameters => parameters.Add(p => p.Id, "show-1"));
        OpenShowSettings(cut);

        // No override → the stepper shows the resolved global value and an "Override" button
        // rather than the −/value/+ controls.
        cut.WaitForAssertion(() =>
        {
            Assert.Contains("Override", cut.Find("#show-auto-skip-intro").TextContent);
            Assert.Empty(cut.FindAll("#show-auto-skip-intro .stepper-value"));
            Assert.Contains("Override", cut.Find("#show-auto-skip-outro").TextContent);
        });
    }

    [Fact]
    public void AutoSkipSelectors_ShowExistingOverride_AtAnySecondsValue()
    {
        AuthContext.SetAuthorized("user-1");
        var existing = new ShowSettings(
            "user-1:show-1", "user-1", "show-1", null, Version: 2,
            AutoSkipIntroSeconds: 15, AutoSkipOutroSeconds: 42);
        ConfigureApi(CreateHandler(showSettings: existing));

        var cut = RenderComponent<ShowDetail>(parameters => parameters.Add(p => p.Id, "show-1"));
        OpenShowSettings(cut);

        // The stepper represents any int directly — no preset list, no synthesized "custom" row.
        cut.WaitForAssertion(() =>
        {
            Assert.Equal("15s", cut.Find("#show-auto-skip-intro .stepper-value").TextContent.Trim());
            Assert.Equal("42s", cut.Find("#show-auto-skip-outro .stepper-value").TextContent.Trim());
        });
    }

    [Fact]
    public void AutoSkipSelector_SavesOverride_WhenChanged()
    {
        AuthContext.SetAuthorized("user-1");
        ConfigureApi(CreateHandler());

        var cut = RenderComponent<ShowDetail>(parameters => parameters.Add(p => p.Id, "show-1"));
        OpenShowSettings(cut);
        cut.WaitForAssertion(() => Assert.Contains("Auto-skip intro", cut.Markup));

        // Start overriding, then bump the stepper up one step.
        cut.FindAll("#show-auto-skip-intro button").Single(b => b.TextContent.Trim() == "Override").Click();
        cut.WaitForElement("#show-auto-skip-intro button[aria-label='Increase']").Click();

        cut.WaitForAssertion(() =>
        {
            Assert.Contains("Saved.", cut.Markup);
            Assert.Equal("5s", cut.Find("#show-auto-skip-intro .stepper-value").TextContent.Trim());
        });
    }

    [Fact]
    public void AutoSkipSelector_ClearsOverride_WhenUseGlobalDefaultClicked()
    {
        AuthContext.SetAuthorized("user-1");
        var existing = new ShowSettings(
            "user-1:show-1", "user-1", "show-1", null, Version: 2, AutoSkipIntroSeconds: 15);
        ConfigureApi(CreateHandler(showSettings: existing));

        var cut = RenderComponent<ShowDetail>(parameters => parameters.Add(p => p.Id, "show-1"));
        OpenShowSettings(cut);
        cut.WaitForAssertion(
            () => Assert.Equal("15s", cut.Find("#show-auto-skip-intro .stepper-value").TextContent.Trim()));

        cut.FindAll("#show-auto-skip-intro button").Single(b => b.TextContent.Trim() == "Use global default").Click();

        cut.WaitForAssertion(() =>
        {
            Assert.Contains("Saved.", cut.Markup);
            Assert.Empty(cut.FindAll("#show-auto-skip-intro .stepper-value"));
            Assert.Contains("Override", cut.Find("#show-auto-skip-intro").TextContent);
        });
    }

    [Fact]
    public void PlaybackSpeedSelector_ShowsExistingOverride()
    {
        AuthContext.SetAuthorized("user-1");
        var existing = new ShowSettings(
            "user-1:show-1", "user-1", "show-1", null, Version: 2, PlaybackSpeed: 1.5f);
        ConfigureApi(CreateHandler(showSettings: existing));

        var cut = RenderComponent<ShowDetail>(parameters => parameters.Add(p => p.Id, "show-1"));
        OpenShowSettings(cut);

        cut.WaitForAssertion(() =>
        {
            Assert.Equal("1.5", cut.Find("#show-playback-speed input[type=range]").GetAttribute("value"));
            Assert.Equal("1.5x", cut.Find("#show-playback-speed .slider-value").TextContent.Trim());
        });
    }

    [Fact]
    public void PlaybackSpeedSelector_SavesOverride_WhenChanged()
    {
        AuthContext.SetAuthorized("user-1");
        ConfigureApi(CreateHandler());

        var cut = RenderComponent<ShowDetail>(parameters => parameters.Add(p => p.Id, "show-1"));
        OpenShowSettings(cut);
        cut.WaitForAssertion(() => Assert.Contains("Playback speed", cut.Markup));

        cut.FindAll("#show-playback-speed button").Single(b => b.TextContent.Trim() == "Override").Click();
        cut.WaitForElement("#show-playback-speed input[type=range]").Change("1.2");

        cut.WaitForAssertion(() =>
        {
            Assert.Contains("Saved.", cut.Markup);
            Assert.Equal("1.2x", cut.Find("#show-playback-speed .slider-value").TextContent.Trim());
        });
    }

    [Fact]
    public void SmartSpeedSelector_ShowsExistingOverride()
    {
        AuthContext.SetAuthorized("user-1");
        var existing = new ShowSettings(
            "user-1:show-1", "user-1", "show-1", null, Version: 2, SmartSpeed: true);
        ConfigureApi(CreateHandler(showSettings: existing));

        var cut = RenderComponent<ShowDetail>(parameters => parameters.Add(p => p.Id, "show-1"));
        OpenShowSettings(cut);

        cut.WaitForAssertion(() => Assert.Equal("On", SelectedChoice(cut, "show-smart-speed")));
    }

    [Fact]
    public void NotificationsSelector_SavesOverride_WhenChanged()
    {
        AuthContext.SetAuthorized("user-1");
        ConfigureApi(CreateHandler());

        var cut = RenderComponent<ShowDetail>(parameters => parameters.Add(p => p.Id, "show-1"));
        OpenShowSettings(cut);
        cut.WaitForAssertion(() => Assert.Contains("Notifications", cut.Markup));

        Choice(cut, "show-notifications-enabled", "Off").Click();

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
        OpenShowSettings(cut);

        cut.WaitForAssertion(() => Assert.Contains("Something went wrong while loading this show's settings", cut.Markup));
    }

    [Fact]
    public void ShowsAutoPlayedIndicatorAndRestoreButton_ForAutoPlayedEpisode()
    {
        AuthContext.SetAuthorized("user-1");
        var autoPlayedState = new EpisodeState("ep-1", "user-1", "ep-1", "show-1", 0, true, DateTimeOffset.UtcNow, null, AutoPlayed: true);
        ConfigureApi(CreateHandler(episodeState: autoPlayedState));

        var cut = RenderComponent<ShowDetail>(parameters => parameters.Add(p => p.Id, "show-1"));
        cut.WaitForAssertion(() => cut.FindAll(".btn-group button").Any(b => b.TextContent.Trim() == "All"));
        cut.FindAll(".btn-group button").Single(b => b.TextContent.Trim() == "All").Click();

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
        cut.WaitForAssertion(() => cut.FindAll(".btn-group button").Any(b => b.TextContent.Trim() == "All"));
        cut.FindAll(".btn-group button").Single(b => b.TextContent.Trim() == "All").Click();
        cut.WaitForAssertion(() => Assert.Contains("Auto-marked played", cut.Markup));

        cut.Find("li button.btn-outline-secondary").Click();

        cut.WaitForAssertion(() => Assert.DoesNotContain("Auto-marked played", cut.Markup));
    }

    [Fact]
    public void UnfinishedFilter_IsActiveByDefault_AndShowsUnplayedAndInProgressEpisodes()
    {
        AuthContext.SetAuthorized("user-1");
        var inProgressState = new EpisodeState("s1", "user-1", "ep-1", "show-1", 300, false, DateTimeOffset.UtcNow, "web");
        ConfigureApi(CreateHandlerWithEpisodes(
            [TestEpisode, OlderEpisode],
            new Dictionary<string, EpisodeState> { ["ep-1"] = inProgressState }));

        var cut = RenderComponent<ShowDetail>(parameters => parameters.Add(p => p.Id, "show-1"));
        cut.WaitForAssertion(() =>
        {
            // Monday is in progress, Sunday is unplayed — both belong in the default view.
            Assert.Contains("Monday Edition", cut.Markup);
            Assert.Contains("Sunday Edition", cut.Markup);
        });
        Assert.Contains("active", cut.FindAll(".btn-group button")
            .Single(b => b.TextContent.Trim() == "Unfinished").ClassList);

        cut.FindAll(".btn-group button").Single(b => b.TextContent.Trim() == "Unplayed").Click();
        cut.WaitForAssertion(() =>
        {
            Assert.DoesNotContain("Monday Edition", cut.Markup);
            Assert.Contains("Sunday Edition", cut.Markup);
        });

        cut.FindAll(".btn-group button").Single(b => b.TextContent.Trim() == "In Progress").Click();
        cut.WaitForAssertion(() =>
        {
            Assert.Contains("Monday Edition", cut.Markup);
            Assert.DoesNotContain("Sunday Edition", cut.Markup);
        });
    }

    [Fact]
    public void UnfinishedFilter_HidesPlayedEpisodes()
    {
        AuthContext.SetAuthorized("user-1");
        var playedState = new EpisodeState("s1", "user-1", "ep-1", "show-1", 1200, true, DateTimeOffset.UtcNow, "web", AutoPlayed: false);
        ConfigureApi(CreateHandlerWithEpisodes(
            [TestEpisode, OlderEpisode],
            new Dictionary<string, EpisodeState> { ["ep-1"] = playedState }));

        var cut = RenderComponent<ShowDetail>(parameters => parameters.Add(p => p.Id, "show-1"));

        cut.WaitForAssertion(() =>
        {
            Assert.DoesNotContain("Monday Edition", cut.Markup);
            Assert.Contains("Sunday Edition", cut.Markup);
        });
    }

    [Fact]
    public void DefaultView_HidesAutoPlayedEpisodes()
    {
        AuthContext.SetAuthorized("user-1");
        var autoPlayedState = new EpisodeState("ep-1", "user-1", "ep-1", "show-1", 0, true, DateTimeOffset.UtcNow, null, AutoPlayed: true);
        ConfigureApi(CreateHandlerWithEpisodes(
            [TestEpisode, OlderEpisode],
            new Dictionary<string, EpisodeState> { ["ep-1"] = autoPlayedState }));

        var cut = RenderComponent<ShowDetail>(parameters => parameters.Add(p => p.Id, "show-1"));

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
        cut.WaitForAssertion(() => cut.FindAll(".btn-group button").Any(b => b.TextContent.Trim() == "All"));
        cut.FindAll(".btn-group button").Single(b => b.TextContent.Trim() == "All").Click();

        cut.WaitForAssertion(() => Assert.Contains("progress-bar", cut.Markup));
    }

    [Fact]
    public void ShowsPlayedBadge_ForCompletedNonAutoPlayedEpisode()
    {
        AuthContext.SetAuthorized("user-1");
        var playedState = new EpisodeState("s1", "user-1", "ep-1", "show-1", 1200, true, DateTimeOffset.UtcNow, "web", AutoPlayed: false);
        ConfigureApi(CreateHandler(episodeState: playedState));

        var cut = RenderComponent<ShowDetail>(parameters => parameters.Add(p => p.Id, "show-1"));
        cut.WaitForAssertion(() => cut.FindAll(".btn-group button").Any(b => b.TextContent.Trim() == "All"));
        cut.FindAll(".btn-group button").Single(b => b.TextContent.Trim() == "All").Click();

        cut.WaitForAssertion(() =>
        {
            Assert.Contains("Played", cut.Markup);
            Assert.DoesNotContain("Auto-marked played", cut.Markup);
        });
    }

    // #617: the API only paginates the raw, unfiltered episode list, while the default
    // "Unfinished" filter is applied client-side afterward. A show whose entire back catalogue is
    // already played (e.g. via "Mark all played") used to leave "Load more" showing forever — each
    // click fetched another raw page that the filter dropped just as completely, with no way for
    // the user to tell whether one more click would ever reveal anything. The fix auto-continues
    // fetching raw pages, bounded, until either something becomes visible under the filter or the
    // raw pagination is actually exhausted.
    [Fact]
    public void LoadMore_AutoContinuesPastPagesTheFilterDrops_UntilPaginationIsExhausted()
    {
        AuthContext.SetAuthorized("user-1");

        var episodeA = new Episode("ep-a", "show-1", "Episode A", DateTimeOffset.UtcNow, TimeSpan.FromMinutes(20), "https://audio-a", null, null, null);
        var episodeB = new Episode("ep-b", "show-1", "Episode B", DateTimeOffset.UtcNow.AddDays(-1), TimeSpan.FromMinutes(20), "https://audio-b", null, null, null);
        var episodeC = new Episode("ep-c", "show-1", "Episode C", DateTimeOffset.UtcNow.AddDays(-2), TimeSpan.FromMinutes(20), "https://audio-c", null, null, null);

        var states = new Dictionary<string, EpisodeState>
        {
            ["ep-a"] = new("s-a", "user-1", "ep-a", "show-1", 1200, true, DateTimeOffset.UtcNow, "web", AutoPlayed: false),
            ["ep-b"] = new("s-b", "user-1", "ep-b", "show-1", 1200, true, DateTimeOffset.UtcNow, "web", AutoPlayed: false),
            ["ep-c"] = new("s-c", "user-1", "ep-c", "show-1", 1200, true, DateTimeOffset.UtcNow, "web", AutoPlayed: false),
        };

        var episodesRequestCount = 0;
        var handler = new TestHttpMessageHandler(request =>
        {
            var path = request.RequestUri!.AbsolutePath;
            if (path == "/api/shows/show-1" && request.Method == HttpMethod.Get)
            {
                return new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(TestShow) };
            }

            if (path == "/api/shows/show-1/episodes" && request.Method == HttpMethod.Get)
            {
                episodesRequestCount++;
                var query = request.RequestUri!.Query;
                var page = !query.Contains("continuationToken=")
                    ? new EpisodePage([episodeA], "page-2")
                    : query.Contains("continuationToken=page-2")
                        ? new EpisodePage([episodeB], "page-3")
                        : query.Contains("continuationToken=page-3")
                            ? new EpisodePage([episodeC], null)
                            : new EpisodePage([], null);
                return new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(page) };
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
        ConfigureApi(handler);

        var cut = RenderComponent<ShowDetail>(parameters => parameters.Add(p => p.Id, "show-1"));

        // Default filter is "Unfinished" — every episode on every page is already played, so it
        // should keep paging through show-1's whole (3-page) back catalogue on its own and land on
        // "no more raw pages" rather than stopping after the first empty page.
        cut.WaitForAssertion(() =>
        {
            Assert.Contains("No episodes match this filter.", cut.Markup);
            Assert.DoesNotContain("Load more", cut.Markup);
        });
        Assert.Equal(3, episodesRequestCount);
    }
}
