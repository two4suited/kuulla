using System.Net;
using System.Net.Http.Json;
using Kuulla.Web.Components.Pages;
using Kuulla.Web.Models;

namespace Kuulla.Web.Tests.Pages;

public class SettingsTests : WebTestContext
{
    private static readonly UserSettings DefaultSettings = new("user-1", UnlistenedEpisodeCount.Five, Version: 1, AutoArchiveRule.Never);

    private static TestHttpMessageHandler CreateHandler(
        UserSettings? getResponse = null, UserSettings? putResponse = null, UserSettings? archivePutResponse = null,
        UserSettings? autoSkipPutResponse = null, UserSettings? playbackSpeedPutResponse = null,
        UserSettings? autoDeletePutResponse = null, UserSettings? autoDownloadPutResponse = null) =>
        new(request =>
        {
            if (request.RequestUri!.AbsolutePath == "/api/settings" && request.Method == HttpMethod.Get)
            {
                return new HttpResponseMessage(HttpStatusCode.OK)
                {
                    Content = JsonContent.Create(getResponse ?? DefaultSettings),
                };
            }

            if (request.RequestUri!.AbsolutePath == "/api/settings" && request.Method == HttpMethod.Put)
            {
                return new HttpResponseMessage(HttpStatusCode.OK)
                {
                    Content = JsonContent.Create(putResponse ?? DefaultSettings),
                };
            }

            if (request.RequestUri!.AbsolutePath == "/api/settings/auto-archive" && request.Method == HttpMethod.Put)
            {
                return new HttpResponseMessage(HttpStatusCode.OK)
                {
                    Content = JsonContent.Create(archivePutResponse ?? DefaultSettings),
                };
            }

            if (request.RequestUri!.AbsolutePath == "/api/settings/auto-skip" && request.Method == HttpMethod.Put)
            {
                return new HttpResponseMessage(HttpStatusCode.OK)
                {
                    Content = JsonContent.Create(autoSkipPutResponse ?? DefaultSettings),
                };
            }

            if (request.RequestUri!.AbsolutePath == "/api/settings/playback-speed" && request.Method == HttpMethod.Put)
            {
                return new HttpResponseMessage(HttpStatusCode.OK)
                {
                    Content = JsonContent.Create(playbackSpeedPutResponse ?? DefaultSettings),
                };
            }

            if (request.RequestUri!.AbsolutePath == "/api/settings/auto-delete" && request.Method == HttpMethod.Put)
            {
                return new HttpResponseMessage(HttpStatusCode.OK)
                {
                    Content = JsonContent.Create(autoDeletePutResponse ?? DefaultSettings),
                };
            }

            if (request.RequestUri!.AbsolutePath == "/api/settings/auto-download" && request.Method == HttpMethod.Put)
            {
                return new HttpResponseMessage(HttpStatusCode.OK)
                {
                    Content = JsonContent.Create(autoDownloadPutResponse ?? DefaultSettings),
                };
            }

            return new HttpResponseMessage(HttpStatusCode.NotFound);
        });

    public SettingsTests()
    {
        AuthContext.SetAuthorized("user-1");
    }

    [Fact]
    public void RendersCurrentSetting_WhenLoadSucceeds()
    {
        ConfigureApi(CreateHandler());

        var cut = RenderComponent<Settings>();

        cut.WaitForAssertion(() => Assert.Equal("Five", cut.Find("#unlistened-episode-count").GetAttribute("value")));
    }

    [Fact]
    public void ShowsErrorMessage_WhenLoadFails()
    {
        ConfigureApi(TestHttpMessageHandler.Status(HttpStatusCode.InternalServerError));

        var cut = RenderComponent<Settings>();

        cut.WaitForAssertion(() => Assert.Contains("Something went wrong", cut.Markup));
    }

    [Fact]
    public void SavesAndConfirms_WhenSelectionChanges()
    {
        ConfigureApi(CreateHandler(putResponse: new("user-1", UnlistenedEpisodeCount.Unlimited, Version: 2)));

        var cut = RenderComponent<Settings>();
        cut.WaitForAssertion(() => Assert.Contains("Unlistened episodes", cut.Markup));

        cut.Find("#unlistened-episode-count").Change("Unlimited");

        cut.WaitForAssertion(() => Assert.Contains("Saved.", cut.Markup));
    }

    [Fact]
    public void ShowsErrorAndReverts_WhenSaveFails()
    {
        ConfigureApi(new TestHttpMessageHandler(request =>
            request.Method == HttpMethod.Put
                ? new HttpResponseMessage(HttpStatusCode.InternalServerError)
                : new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(DefaultSettings) }));

        var cut = RenderComponent<Settings>();
        cut.WaitForAssertion(() => Assert.Equal("Five", cut.Find("#unlistened-episode-count").GetAttribute("value")));

        cut.Find("#unlistened-episode-count").Change("Unlimited");

        cut.WaitForAssertion(() =>
        {
            Assert.Contains("Something went wrong", cut.Markup);
            Assert.Equal("Five", cut.Find("#unlistened-episode-count").GetAttribute("value"));
        });
    }

    [Fact]
    public void RendersCurrentAutoArchiveRule_WhenLoadSucceeds()
    {
        ConfigureApi(CreateHandler(getResponse: new("user-1", UnlistenedEpisodeCount.Five, Version: 1, AutoArchiveRule.After7Days)));

        var cut = RenderComponent<Settings>();

        cut.WaitForAssertion(() => Assert.Equal("After7Days", cut.Find("#auto-archive-rule").GetAttribute("value")));
    }

    [Fact]
    public void SavesAndConfirmsAutoArchiveRule_WhenSelectionChanges()
    {
        ConfigureApi(CreateHandler(archivePutResponse: new("user-1", UnlistenedEpisodeCount.Five, Version: 2, AutoArchiveRule.AfterPlayed)));

        var cut = RenderComponent<Settings>();
        cut.WaitForAssertion(() => Assert.Contains("Auto-archive", cut.Markup));

        cut.Find("#auto-archive-rule").Change("AfterPlayed");

        cut.WaitForAssertion(() => Assert.Contains("Saved.", cut.Markup));
    }

    [Fact]
    public void RendersCurrentAutoSkipSeconds_WhenLoadSucceeds()
    {
        ConfigureApi(CreateHandler(getResponse: new(
            "user-1", UnlistenedEpisodeCount.Five, Version: 1, AutoArchiveRule.Never,
            AutoSkipIntroSeconds: 15, AutoSkipOutroSeconds: 30)));

        var cut = RenderComponent<Settings>();

        cut.WaitForAssertion(() =>
        {
            Assert.Equal("15", cut.Find("#auto-skip-intro-seconds").GetAttribute("value"));
            Assert.Equal("30", cut.Find("#auto-skip-outro-seconds").GetAttribute("value"));
        });
    }

    [Fact]
    public void SavesAndConfirmsAutoSkipSeconds_WhenSelectionChanges()
    {
        ConfigureApi(CreateHandler(autoSkipPutResponse: new(
            "user-1", UnlistenedEpisodeCount.Five, Version: 2, AutoArchiveRule.Never,
            AutoSkipIntroSeconds: 10, AutoSkipOutroSeconds: 0)));

        var cut = RenderComponent<Settings>();
        cut.WaitForAssertion(() => Assert.Contains("Auto-skip intro", cut.Markup));

        cut.Find("#auto-skip-intro-seconds").Change("10");

        cut.WaitForAssertion(() => Assert.Contains("Saved.", cut.Markup));
    }

    [Fact]
    public void ShowsErrorAndRevertsAutoSkipSeconds_WhenSaveFails()
    {
        ConfigureApi(new TestHttpMessageHandler(request =>
            request.RequestUri!.AbsolutePath == "/api/settings/auto-skip" && request.Method == HttpMethod.Put
                ? new HttpResponseMessage(HttpStatusCode.InternalServerError)
                : new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(DefaultSettings) }));

        var cut = RenderComponent<Settings>();
        cut.WaitForAssertion(() => Assert.Equal("0", cut.Find("#auto-skip-intro-seconds").GetAttribute("value")));

        cut.Find("#auto-skip-intro-seconds").Change("10");

        cut.WaitForAssertion(() =>
        {
            Assert.Contains("Something went wrong", cut.Markup);
            Assert.Equal("0", cut.Find("#auto-skip-intro-seconds").GetAttribute("value"));
        });
    }

    [Fact]
    public void RendersCurrentPlaybackSpeed_WhenLoadSucceeds()
    {
        ConfigureApi(CreateHandler(getResponse: new(
            "user-1", UnlistenedEpisodeCount.Five, Version: 1, AutoArchiveRule.Never,
            AutoSkipIntroSeconds: 0, AutoSkipOutroSeconds: 0, PlaybackSpeed: 1.5f)));

        var cut = RenderComponent<Settings>();

        cut.WaitForAssertion(() => Assert.Equal("1.5", cut.Find("#playback-speed").GetAttribute("value")));
    }

    [Fact]
    public void SavesAndConfirmsPlaybackSpeed_WhenSelectionChanges()
    {
        ConfigureApi(CreateHandler(playbackSpeedPutResponse: new(
            "user-1", UnlistenedEpisodeCount.Five, Version: 2, AutoArchiveRule.Never,
            AutoSkipIntroSeconds: 0, AutoSkipOutroSeconds: 0, PlaybackSpeed: 1.2f)));

        var cut = RenderComponent<Settings>();
        cut.WaitForAssertion(() => Assert.Contains("Playback speed", cut.Markup));

        cut.Find("#playback-speed").Change("1.2");

        cut.WaitForAssertion(() => Assert.Contains("Saved.", cut.Markup));
    }

    [Fact]
    public void ShowsErrorAndRevertsPlaybackSpeed_WhenSaveFails()
    {
        ConfigureApi(new TestHttpMessageHandler(request =>
            request.RequestUri!.AbsolutePath == "/api/settings/playback-speed" && request.Method == HttpMethod.Put
                ? new HttpResponseMessage(HttpStatusCode.InternalServerError)
                : new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(DefaultSettings) }));

        var cut = RenderComponent<Settings>();
        cut.WaitForAssertion(() => Assert.Equal("1", cut.Find("#playback-speed").GetAttribute("value")));

        cut.Find("#playback-speed").Change("1.2");

        cut.WaitForAssertion(() =>
        {
            Assert.Contains("Something went wrong", cut.Markup);
            Assert.Equal("1", cut.Find("#playback-speed").GetAttribute("value"));
        });
    }

    [Fact]
    public void RendersCurrentAutoDownloadNewEpisodes_WhenLoadSucceeds()
    {
        ConfigureApi(CreateHandler(getResponse: new(
            "user-1", UnlistenedEpisodeCount.Five, Version: 1, AutoArchiveRule.Never,
            AutoDownloadNewEpisodes: true)));

        var cut = RenderComponent<Settings>();

        cut.WaitForAssertion(() => Assert.True(cut.Find("#auto-download-new-episodes").HasAttribute("checked")));
    }

    [Fact]
    public void SavesAndConfirmsAutoDownloadNewEpisodes_WhenToggled()
    {
        ConfigureApi(CreateHandler(autoDownloadPutResponse: new(
            "user-1", UnlistenedEpisodeCount.Five, Version: 2, AutoArchiveRule.Never,
            AutoDownloadNewEpisodes: true)));

        var cut = RenderComponent<Settings>();
        cut.WaitForAssertion(() => Assert.Contains("Auto-download new episodes", cut.Markup));

        cut.Find("#auto-download-new-episodes").Change(true);

        cut.WaitForAssertion(() => Assert.Contains("Saved.", cut.Markup));
    }

    [Fact]
    public void RendersCurrentAutoDeleteRule_WhenLoadSucceeds()
    {
        ConfigureApi(CreateHandler(getResponse: new(
            "user-1", UnlistenedEpisodeCount.Five, Version: 1, AutoArchiveRule.Never,
            AutoDeleteRule: AutoDeleteRule.AfterPlayed)));

        var cut = RenderComponent<Settings>();

        cut.WaitForAssertion(() => Assert.Equal("AfterPlayed", cut.Find("#auto-delete-rule").GetAttribute("value")));
    }

    [Fact]
    public void ShowsAfterDaysInput_WhenRuleIsAfterDays()
    {
        ConfigureApi(CreateHandler(getResponse: new(
            "user-1", UnlistenedEpisodeCount.Five, Version: 1, AutoArchiveRule.Never,
            AutoDeleteRule: AutoDeleteRule.AfterDays, AutoDeleteAfterDays: 14)));

        var cut = RenderComponent<Settings>();

        cut.WaitForAssertion(() => Assert.Equal("14", cut.Find("#auto-delete-after-days").GetAttribute("value")));
    }

    [Fact]
    public void HidesAfterDaysInput_WhenRuleIsNotAfterDays()
    {
        ConfigureApi(CreateHandler(getResponse: new(
            "user-1", UnlistenedEpisodeCount.Five, Version: 1, AutoArchiveRule.Never,
            AutoDeleteRule: AutoDeleteRule.Never)));

        var cut = RenderComponent<Settings>();

        cut.WaitForAssertion(() => Assert.Contains("Delete downloads", cut.Markup));
        Assert.Empty(cut.FindAll("#auto-delete-after-days"));
    }

    [Fact]
    public void SavesAndConfirmsAutoDeleteAfterDays_WhenInputChanges()
    {
        ConfigureApi(CreateHandler(
            getResponse: new(
                "user-1", UnlistenedEpisodeCount.Five, Version: 1, AutoArchiveRule.Never,
                AutoDeleteRule: AutoDeleteRule.AfterDays, AutoDeleteAfterDays: 7),
            autoDeletePutResponse: new(
                "user-1", UnlistenedEpisodeCount.Five, Version: 2, AutoArchiveRule.Never,
                AutoDeleteRule: AutoDeleteRule.AfterDays, AutoDeleteAfterDays: 21)));

        var cut = RenderComponent<Settings>();
        cut.WaitForAssertion(() => Assert.Equal("7", cut.Find("#auto-delete-after-days").GetAttribute("value")));

        cut.Find("#auto-delete-after-days").Change("21");

        cut.WaitForAssertion(() => Assert.Contains("Saved.", cut.Markup));
    }

    [Fact]
    public void SavesAndConfirmsAutoDeleteRule_WhenSelectionChanges()
    {
        ConfigureApi(CreateHandler(autoDeletePutResponse: new(
            "user-1", UnlistenedEpisodeCount.Five, Version: 2, AutoArchiveRule.Never,
            AutoDeleteRule: AutoDeleteRule.AfterPlayed)));

        var cut = RenderComponent<Settings>();
        cut.WaitForAssertion(() => Assert.Contains("Delete downloads", cut.Markup));

        cut.Find("#auto-delete-rule").Change("AfterPlayed");

        cut.WaitForAssertion(() => Assert.Contains("Saved.", cut.Markup));
    }

    [Fact]
    public void ShowsErrorAndRevertsAutoDeleteRule_WhenSaveFails()
    {
        ConfigureApi(new TestHttpMessageHandler(request =>
            request.RequestUri!.AbsolutePath == "/api/settings/auto-delete" && request.Method == HttpMethod.Put
                ? new HttpResponseMessage(HttpStatusCode.InternalServerError)
                : new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(DefaultSettings) }));

        var cut = RenderComponent<Settings>();
        cut.WaitForAssertion(() => Assert.Equal("Never", cut.Find("#auto-delete-rule").GetAttribute("value")));

        cut.Find("#auto-delete-rule").Change("AfterPlayed");

        cut.WaitForAssertion(() =>
        {
            Assert.Contains("Something went wrong", cut.Markup);
            Assert.Equal("Never", cut.Find("#auto-delete-rule").GetAttribute("value"));
        });
    }
}
