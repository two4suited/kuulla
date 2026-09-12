using System.Net;
using System.Net.Http.Json;
using Bunit;
using Kuulla.Web.Components.Pages;
using Kuulla.Web.Models;
using Kuulla.Web.Services.Sync;
using Microsoft.JSInterop;

namespace Kuulla.Web.Tests.Pages;

public class SettingsTests : WebTestContext
{
    private static readonly UserSettings DefaultSettings = new("user-1", UnlistenedEpisodeCount.Five, Version: 1, AutoArchiveRule.Never);

    // SyncCheckResult<UserSettings> is the same (ServerChanges, SyncedAt, Hash) shape the real
    // API response deserializes into (SettingsClient.SyncAsync) — reused here rather than a
    // separate stub record, so this stays in lockstep with the actual wire contract.
    private static readonly SyncCheckResult<UserSettings> EmptySync = new([], DateTimeOffset.UtcNow, "hash-1");

    private static TestHttpMessageHandler CreateHandler(
        UserSettings? getResponse = null, UserSettings? putResponse = null, UserSettings? archivePutResponse = null,
        UserSettings? autoSkipPutResponse = null, UserSettings? playbackSpeedPutResponse = null,
        UserSettings? autoDeletePutResponse = null, UserSettings? autoDownloadPutResponse = null,
        UserSettings? smartSpeedPutResponse = null, UserSettings? sleepTimerDefaultDurationPutResponse = null,
        UserSettings? playNextPutResponse = null,
        Func<HttpRequestMessage, HttpResponseMessage>? onSync = null,
        Func<HttpRequestMessage, HttpResponseMessage>? onImport = null,
        Func<HttpRequestMessage, HttpResponseMessage>? onExport = null) =>
        new(request =>
        {
            if (request.RequestUri!.AbsolutePath == "/api/subscriptions/import" && request.Method == HttpMethod.Post)
            {
                return onImport?.Invoke(request) ??
                    new HttpResponseMessage(HttpStatusCode.OK)
                    {
                        Content = JsonContent.Create(new { added = 0, alreadySubscribed = 0, failed = Array.Empty<object>() }),
                    };
            }

            if (request.RequestUri!.AbsolutePath == "/api/subscriptions/export" && request.Method == HttpMethod.Get)
            {
                return onExport?.Invoke(request) ??
                    new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("<opml version=\"2.0\"><body/></opml>") };
            }

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

            if (request.RequestUri!.AbsolutePath == "/api/settings/smart-speed" && request.Method == HttpMethod.Put)
            {
                return new HttpResponseMessage(HttpStatusCode.OK)
                {
                    Content = JsonContent.Create(smartSpeedPutResponse ?? DefaultSettings),
                };
            }

            if (request.RequestUri!.AbsolutePath == "/api/settings/play-next" && request.Method == HttpMethod.Put)
            {
                return new HttpResponseMessage(HttpStatusCode.OK)
                {
                    Content = JsonContent.Create(playNextPutResponse ?? DefaultSettings),
                };
            }

            if (request.RequestUri!.AbsolutePath == "/api/settings/sleep-timer-default-duration" && request.Method == HttpMethod.Put)
            {
                return new HttpResponseMessage(HttpStatusCode.OK)
                {
                    Content = JsonContent.Create(sleepTimerDefaultDurationPutResponse ?? DefaultSettings),
                };
            }

            if (request.RequestUri!.AbsolutePath == "/api/sync/settings" && request.Method == HttpMethod.Post)
            {
                return onSync?.Invoke(request) ??
                    new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(EmptySync) };
            }

            return new HttpResponseMessage(HttpStatusCode.NotFound);
        });

    public SettingsTests()
    {
        AuthContext.SetAuthorized("user-1");
        // Settings.razor reads/writes "wifiOnlyStreaming" via localStorage.getItem/setItem
        // (#273) — Loose mode auto-mocks those calls (returning null/default for unconfigured
        // ones), matching the pattern already used for EpisodeDetail.razor.js's dynamic import.
        JSInterop.Mode = JSRuntimeMode.Loose;
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
    public void ShowsErrorAndRevertsAutoDownloadNewEpisodes_WhenSaveFails()
    {
        ConfigureApi(new TestHttpMessageHandler(request =>
            request.RequestUri!.AbsolutePath == "/api/settings/auto-download" && request.Method == HttpMethod.Put
                ? new HttpResponseMessage(HttpStatusCode.InternalServerError)
                : new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(DefaultSettings) }));

        var cut = RenderComponent<Settings>();
        cut.WaitForAssertion(() => Assert.False(cut.Find("#auto-download-new-episodes").HasAttribute("checked")));

        cut.Find("#auto-download-new-episodes").Change(true);

        cut.WaitForAssertion(() =>
        {
            Assert.Contains("Something went wrong", cut.Markup);
            Assert.False(cut.Find("#auto-download-new-episodes").HasAttribute("checked"));
        });
    }

    [Fact]
    public void RendersCurrentPlayNextBehavior_WhenLoadSucceeds()
    {
        ConfigureApi(CreateHandler(getResponse: new(
            "user-1", UnlistenedEpisodeCount.Five, Version: 1, AutoArchiveRule.Never,
            PlayNextBehavior: PlayNextBehavior.TopOfList)));

        var cut = RenderComponent<Settings>();

        cut.WaitForAssertion(() => Assert.Equal("TopOfList", cut.Find("#play-next").GetAttribute("value")));
    }

    [Fact]
    public void SavesAndConfirmsPlayNextBehavior_WhenChanged()
    {
        string? putBody = null;
        ConfigureApi(new TestHttpMessageHandler(request =>
        {
            if (request.RequestUri!.AbsolutePath == "/api/settings/play-next" && request.Method == HttpMethod.Put)
            {
                putBody = request.Content!.ReadAsStringAsync().GetAwaiter().GetResult();
                return new HttpResponseMessage(HttpStatusCode.OK)
                {
                    Content = JsonContent.Create(new UserSettings(
                        "user-1", UnlistenedEpisodeCount.Five, Version: 2, AutoArchiveRule.Never, PlayNextBehavior: PlayNextBehavior.Stop)),
                };
            }

            return new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(DefaultSettings) };
        }));

        var cut = RenderComponent<Settings>();
        cut.WaitForAssertion(() => cut.Find("#play-next"));

        cut.Find("#play-next").Change("Stop");

        cut.WaitForAssertion(() =>
        {
            Assert.Contains("Saved.", cut.Markup);
            // Enum values travel as their integer, same as every other settings PUT.
            Assert.Contains($"\"playNextBehavior\":{(int)PlayNextBehavior.Stop}", putBody);
            Assert.Equal("Stop", cut.Find("#play-next").GetAttribute("value"));
        });
    }

    [Fact]
    public void ShowsErrorAndRevertsPlayNextBehavior_WhenSaveFails()
    {
        ConfigureApi(new TestHttpMessageHandler(request =>
            request.RequestUri!.AbsolutePath == "/api/settings/play-next" && request.Method == HttpMethod.Put
                ? new HttpResponseMessage(HttpStatusCode.InternalServerError)
                : new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(DefaultSettings) }));

        var cut = RenderComponent<Settings>();
        cut.WaitForAssertion(() => Assert.Equal("NextInList", cut.Find("#play-next").GetAttribute("value")));

        cut.Find("#play-next").Change("Stop");

        cut.WaitForAssertion(() =>
        {
            Assert.Contains("Something went wrong", cut.Markup);
            Assert.Equal("NextInList", cut.Find("#play-next").GetAttribute("value"));
        });
    }

    [Fact]
    public void RendersCurrentSmartSpeed_WhenLoadSucceeds()
    {
        ConfigureApi(CreateHandler(getResponse: new(
            "user-1", UnlistenedEpisodeCount.Five, Version: 1, AutoArchiveRule.Never,
            SmartSpeed: true)));

        var cut = RenderComponent<Settings>();

        cut.WaitForAssertion(() => Assert.True(cut.Find("#smart-speed").HasAttribute("checked")));
    }

    [Fact]
    public void SavesAndConfirmsSmartSpeed_WhenToggled()
    {
        ConfigureApi(CreateHandler(smartSpeedPutResponse: new(
            "user-1", UnlistenedEpisodeCount.Five, Version: 2, AutoArchiveRule.Never,
            SmartSpeed: true)));

        var cut = RenderComponent<Settings>();
        cut.WaitForAssertion(() => Assert.Contains("SmartSpeed", cut.Markup));

        cut.Find("#smart-speed").Change(true);

        cut.WaitForAssertion(() => Assert.Contains("Saved.", cut.Markup));
    }

    [Fact]
    public void ShowsErrorAndRevertsSmartSpeed_WhenSaveFails()
    {
        ConfigureApi(new TestHttpMessageHandler(request =>
            request.RequestUri!.AbsolutePath == "/api/settings/smart-speed" && request.Method == HttpMethod.Put
                ? new HttpResponseMessage(HttpStatusCode.InternalServerError)
                : new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(DefaultSettings) }));

        var cut = RenderComponent<Settings>();
        cut.WaitForAssertion(() => Assert.False(cut.Find("#smart-speed").HasAttribute("checked")));

        cut.Find("#smart-speed").Change(true);

        cut.WaitForAssertion(() =>
        {
            Assert.Contains("Something went wrong", cut.Markup);
            Assert.False(cut.Find("#smart-speed").HasAttribute("checked"));
        });
    }

    [Fact]
    public void RendersNotSet_WhenSleepTimerDefaultDurationIsNull()
    {
        ConfigureApi(CreateHandler());

        var cut = RenderComponent<Settings>();

        cut.WaitForAssertion(() => Assert.Equal("", cut.Find("#sleep-timer-default-duration").GetAttribute("value")));
    }

    [Fact]
    public void RendersCurrentSleepTimerDefaultDuration_WhenLoadSucceeds()
    {
        ConfigureApi(CreateHandler(getResponse: new(
            "user-1", UnlistenedEpisodeCount.Five, Version: 1, AutoArchiveRule.Never,
            SleepTimerDefaultDurationMinutes: 30)));

        var cut = RenderComponent<Settings>();

        cut.WaitForAssertion(() => Assert.Equal("30", cut.Find("#sleep-timer-default-duration").GetAttribute("value")));
    }

    [Fact]
    public void SavesAndConfirmsSleepTimerDefaultDuration_WhenSelectionChanges()
    {
        ConfigureApi(CreateHandler(sleepTimerDefaultDurationPutResponse: new(
            "user-1", UnlistenedEpisodeCount.Five, Version: 2, AutoArchiveRule.Never,
            SleepTimerDefaultDurationMinutes: 45)));

        var cut = RenderComponent<Settings>();
        cut.WaitForAssertion(() => Assert.Contains("Default sleep timer duration", cut.Markup));

        cut.Find("#sleep-timer-default-duration").Change("45");

        cut.WaitForAssertion(() => Assert.Contains("Saved.", cut.Markup));
    }

    [Fact]
    public void RemovesNotSetOption_OnceASleepTimerDefaultDurationIsSet()
    {
        // "Not set" is display-only — once a real duration is selected there's no way back to
        // null (the API's update endpoint never clears it), so the option must stop being
        // selectable rather than sticking around and letting the UI drift from the saved value.
        ConfigureApi(CreateHandler(getResponse: new(
            "user-1", UnlistenedEpisodeCount.Five, Version: 1, AutoArchiveRule.Never,
            SleepTimerDefaultDurationMinutes: 30)));

        var cut = RenderComponent<Settings>();

        cut.WaitForAssertion(() =>
        {
            var options = cut.Find("#sleep-timer-default-duration").QuerySelectorAll("option");
            Assert.DoesNotContain(options, o => o.GetAttribute("value") == "");
        });
    }

    [Fact]
    public void ShowsErrorAndRevertsSleepTimerDefaultDuration_WhenSaveFails()
    {
        ConfigureApi(new TestHttpMessageHandler(request =>
            request.RequestUri!.AbsolutePath == "/api/settings/sleep-timer-default-duration" && request.Method == HttpMethod.Put
                ? new HttpResponseMessage(HttpStatusCode.InternalServerError)
                : new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(DefaultSettings) }));

        var cut = RenderComponent<Settings>();
        cut.WaitForAssertion(() => Assert.Equal("", cut.Find("#sleep-timer-default-duration").GetAttribute("value")));

        cut.Find("#sleep-timer-default-duration").Change("45");

        cut.WaitForAssertion(() =>
        {
            Assert.Contains("Something went wrong", cut.Markup);
            Assert.Equal("", cut.Find("#sleep-timer-default-duration").GetAttribute("value"));
        });
    }

    [Fact]
    public void DoesNotSave_WhenNotSetIsSelected()
    {
        // "Not set" is display-only (SleepTimerDurationUi's doc comment) — the API's update
        // endpoint only ever sets a concrete duration, there's no clear-to-null request to send.
        var handler = new TestHttpMessageHandler(request =>
            request.Method == HttpMethod.Put && request.RequestUri!.AbsolutePath == "/api/settings/sleep-timer-default-duration"
                ? throw new InvalidOperationException("Should not PUT when \"Not set\" is selected.")
                : new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(DefaultSettings) });
        ConfigureApi(handler);

        var cut = RenderComponent<Settings>();
        cut.WaitForAssertion(() => Assert.Equal("", cut.Find("#sleep-timer-default-duration").GetAttribute("value")));

        cut.Find("#sleep-timer-default-duration").Change("");
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

    [Fact]
    public void WifiOnlyStreaming_DefaultsToOff_WhenLocalStorageUnset()
    {
        ConfigureApi(CreateHandler());
        JSInterop.Setup<string?>("localStorage.getItem", "wifiOnlyStreaming").SetResult(null);

        var cut = RenderComponent<Settings>();

        cut.WaitForAssertion(() => Assert.False(cut.Find("#wifi-only-streaming").HasAttribute("checked")));
    }

    [Fact]
    public void WifiOnlyStreaming_ReflectsStoredValue()
    {
        ConfigureApi(CreateHandler());
        JSInterop.Setup<string?>("localStorage.getItem", "wifiOnlyStreaming").SetResult("true");

        var cut = RenderComponent<Settings>();

        cut.WaitForAssertion(() => Assert.True(cut.Find("#wifi-only-streaming").HasAttribute("checked")));
    }

    [Fact]
    public void WifiOnlyStreaming_DefaultsToOffAndStaysUsable_WhenLocalStorageReadThrows()
    {
        ConfigureApi(CreateHandler());
        JSInterop.Setup<string?>("localStorage.getItem", "wifiOnlyStreaming").SetException(new JSException("blocked"));

        var cut = RenderComponent<Settings>();

        cut.WaitForAssertion(() =>
        {
            var checkbox = cut.Find("#wifi-only-streaming");
            Assert.False(checkbox.HasAttribute("checked"));
            Assert.False(checkbox.HasAttribute("disabled"));
        });
    }

    [Fact]
    public void WifiOnlyStreaming_StaysToggled_WhenLocalStorageWriteThrows()
    {
        ConfigureApi(CreateHandler());
        JSInterop.Setup<string?>("localStorage.getItem", "wifiOnlyStreaming").SetResult(null);
        JSInterop.SetupVoid("localStorage.setItem", "wifiOnlyStreaming", "true").SetException(new JSException("blocked"));

        var cut = RenderComponent<Settings>();
        cut.WaitForAssertion(() => Assert.False(cut.Find("#wifi-only-streaming").HasAttribute("checked")));

        cut.Find("#wifi-only-streaming").Change(true);

        cut.WaitForAssertion(() => Assert.True(cut.Find("#wifi-only-streaming").HasAttribute("checked")));
    }

    [Fact]
    public void WifiOnlyStreaming_WritesToLocalStorage_WhenToggled()
    {
        ConfigureApi(CreateHandler());
        JSInterop.Setup<string?>("localStorage.getItem", "wifiOnlyStreaming").SetResult(null);

        var cut = RenderComponent<Settings>();
        cut.WaitForAssertion(() => Assert.False(cut.Find("#wifi-only-streaming").HasAttribute("checked")));

        cut.Find("#wifi-only-streaming").Change(true);

        cut.WaitForAssertion(() =>
        {
            var invocation = JSInterop.Invocations["localStorage.setItem"].Last();
            Assert.Equal("wifiOnlyStreaming", invocation.Arguments[0]);
            Assert.Equal("true", invocation.Arguments[1]);
        });
    }

    [Fact]
    public void BootstrapSyncFailure_DoesNotHideAlreadyLoadedSettings()
    {
        ConfigureApi(CreateHandler(onSync: _ => new HttpResponseMessage(HttpStatusCode.InternalServerError)));

        var cut = RenderComponent<Settings>();

        cut.WaitForAssertion(() =>
        {
            Assert.Equal("Five", cut.Find("#unlistened-episode-count").GetAttribute("value"));
            Assert.DoesNotContain("Something went wrong", cut.Markup);
        });
    }

    [Fact]
    public void RemoteUpdate_AppliesServerChangesToRenderedFields()
    {
        ConfigureApi(CreateHandler());
        var cut = RenderComponent<Settings>();
        cut.WaitForAssertion(() => Assert.Equal("Five", cut.Find("#unlistened-episode-count").GetAttribute("value")));

        // Exercises Settings.razor's private ApplyServerChanges(IReadOnlyList<UserSettings>)
        // directly — the same callback SyncStatusService<UserSettings> invokes when a poll
        // returns another device's write — rather than re-deriving SyncStatusService's own
        // polling behavior (already covered by SyncStatusServiceTests).
        var remoteSettings = new UserSettings(
            "user-1", UnlistenedEpisodeCount.Unlimited, Version: 2, AutoArchiveRule.After7Days, PlaybackSpeed: 1.5f);
        var applyServerChanges = cut.Instance.GetType().GetMethod(
            "ApplyServerChanges", System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance)!;

        cut.InvokeAsync(() => applyServerChanges.Invoke(cut.Instance, [new[] { remoteSettings }]));

        cut.WaitForAssertion(() =>
        {
            Assert.Equal("Unlimited", cut.Find("#unlistened-episode-count").GetAttribute("value"));
            Assert.Equal("After7Days", cut.Find("#auto-archive-rule").GetAttribute("value"));
        });
    }

    [Fact]
    public void OpmlImport_ShowsSummary_OnSuccess()
    {
        ConfigureApi(CreateHandler(
            onImport: _ => new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = JsonContent.Create(new
                {
                    added = 1,
                    alreadySubscribed = 2,
                    failed = new[] { new { feedUrl = "https://dead.example/feed", reason = "The feed couldn't be fetched or read." } },
                }),
            }));

        var cut = RenderComponent<Settings>();
        cut.WaitForAssertion(() => Assert.Contains("Import OPML", cut.Markup));

        cut.FindComponent<Microsoft.AspNetCore.Components.Forms.InputFile>()
            .UploadFiles(InputFileContent.CreateFromText("<opml version=\"2.0\"><body/></opml>", "subs.opml"));

        cut.WaitForAssertion(() => Assert.Contains("Added 1, skipped 2 already subscribed, 1 failed.", cut.Markup));

        cut.Find("button.btn-link").Click();
        cut.WaitForAssertion(() => Assert.Contains("https://dead.example/feed", cut.Markup));
    }

    [Fact]
    public void OpmlImport_ShowsFriendlyError_When400()
    {
        ConfigureApi(CreateHandler(onImport: _ => new HttpResponseMessage(HttpStatusCode.BadRequest)));

        var cut = RenderComponent<Settings>();
        cut.WaitForAssertion(() => Assert.Contains("Import OPML", cut.Markup));

        cut.FindComponent<Microsoft.AspNetCore.Components.Forms.InputFile>()
            .UploadFiles(InputFileContent.CreateFromText("not opml", "subs.txt"));

        cut.WaitForAssertion(() => Assert.Contains("couldn't be read as an OPML", cut.Markup));
    }

    [Fact]
    public void OpmlExport_HandsBytesToTheBrowserDownloadHelper_OnSuccess()
    {
        ConfigureApi(CreateHandler(onExport: _ => new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new StringContent("<opml version=\"2.0\"><body><outline type=\"rss\" xmlUrl=\"https://a.example/feed\" /></body></opml>"),
        }));

        var cut = RenderComponent<Settings>();
        cut.WaitForAssertion(() => Assert.Contains("Export OPML", cut.Markup));

        cut.FindAll("button").Single(b => b.TextContent.Trim() == "Export OPML").Click();

        cut.WaitForAssertion(() =>
        {
            var invocation = JSInterop.VerifyInvoke("kuullaDownloadFile");
            Assert.Equal("kuulla-subscriptions.opml", invocation.Arguments[0]);
            Assert.Equal("text/x-opml", invocation.Arguments[1]);
        });
    }

    [Fact]
    public void OpmlExport_ShowsFriendlyError_OnFailure()
    {
        ConfigureApi(CreateHandler(onExport: _ => new HttpResponseMessage(HttpStatusCode.InternalServerError)));

        var cut = RenderComponent<Settings>();
        cut.WaitForAssertion(() => Assert.Contains("Export OPML", cut.Markup));

        cut.FindAll("button").Single(b => b.TextContent.Trim() == "Export OPML").Click();

        cut.WaitForAssertion(() => Assert.Contains("went wrong exporting", cut.Markup));
    }
}
