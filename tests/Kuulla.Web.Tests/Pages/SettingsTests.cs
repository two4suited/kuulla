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
        Func<HttpRequestMessage, HttpResponseMessage>? onSync = null) =>
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
}
