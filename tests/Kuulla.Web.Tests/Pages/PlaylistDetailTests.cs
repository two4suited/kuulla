using System.Net;
using System.Net.Http.Json;
using Bunit;
using Bunit.TestDoubles;
using Kuulla.Web.Models;
using Microsoft.Extensions.DependencyInjection;
using PlaylistDetailPage = Kuulla.Web.Components.Pages.PlaylistDetail;

namespace Kuulla.Web.Tests.Pages;

public class PlaylistDetailTests : WebTestContext
{
    public PlaylistDetailTests()
    {
        // Components/Pages/PlaylistDetail.razor.js isn't loadable under bunit's jsdom-less
        // runtime; Loose mode auto-mocks the dynamic import/attach calls (see EpisodeDetailTests).
        JSInterop.Mode = JSRuntimeMode.Loose;
    }

    private static PlaylistDetail MakeDetail(params PlaylistItemDetail[] items) =>
        new("playlist-1", "Commute", PlaylistType.Manual, items, DateTimeOffset.UtcNow, DateTimeOffset.UtcNow);

    private static PlaylistDetail MakeUpNextDetail(params PlaylistItemDetail[] items) =>
        new("up-next-1", "Up Next", PlaylistType.Manual, items, DateTimeOffset.UtcNow, DateTimeOffset.UtcNow);

    private static readonly UserSettings DefaultSettings =
        new("user-1", UnlistenedEpisodeCount.Five, Version: 1, AutoArchiveRule.Never);

    // Serves an Up Next playlist plus the settings GET/PUTs its edit panel now drives (#510).
    private static TestHttpMessageHandler UpNextHandler(
        PlaylistDetail detail, UserSettings? settings = null,
        Func<HttpRequestMessage, HttpResponseMessage>? onSettingsPut = null) => new(request =>
    {
        var path = request.RequestUri!.AbsolutePath;

        if (path == "/api/playlists/up-next-1" && request.Method == HttpMethod.Get)
        {
            return new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(detail) };
        }

        if (path == "/api/episodes/states" && request.Method == HttpMethod.Post)
        {
            return new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(new Dictionary<string, EpisodeState>()) };
        }

        if (path == "/api/sync/playlists")
        {
            return new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = JsonContent.Create(new { ServerChanges = Array.Empty<Playlist>(), SyncedAt = DateTimeOffset.UtcNow, Hash = "h1" }),
            };
        }

        if (path == "/api/settings" && request.Method == HttpMethod.Get)
        {
            return new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(settings ?? DefaultSettings) };
        }

        if (path.StartsWith("/api/settings/") && request.Method == HttpMethod.Put)
        {
            return onSettingsPut?.Invoke(request)
                ?? new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(settings ?? DefaultSettings) };
        }

        return new HttpResponseMessage(HttpStatusCode.NotFound);
    });

    [Fact]
    public void RendersPlaylistItems_WhenLoadSucceeds()
    {
        var detail = MakeDetail(new PlaylistItemDetail("episode-1", "show-1", "Episode One", null, DateTimeOffset.UtcNow, "m"));
        ConfigureApi(TestHttpMessageHandler.Json(detail));

        var cut = RenderComponent<PlaylistDetailPage>(parameters => parameters.Add(p => p.Id, "playlist-1"));

        cut.WaitForAssertion(() =>
        {
            Assert.Contains("Commute", cut.Markup);
            Assert.Contains("Episode One", cut.Markup);
        });
    }

    [Fact]
    public void ShowsEmptyMessage_WhenPlaylistHasNoItems()
    {
        ConfigureApi(TestHttpMessageHandler.Json(MakeDetail()));

        var cut = RenderComponent<PlaylistDetailPage>(parameters => parameters.Add(p => p.Id, "playlist-1"));

        // Unplayed-only is the default filter, so an empty playlist shows the unplayed-specific
        // empty state rather than the generic "this playlist is empty" message.
        cut.WaitForAssertion(() => Assert.Contains("No unplayed episodes are in this playlist", cut.Markup));
    }

    [Fact]
    public void ShowsNotFoundMessage_WhenPlaylistDoesNotExist()
    {
        ConfigureApi(TestHttpMessageHandler.Status(HttpStatusCode.NotFound));

        var cut = RenderComponent<PlaylistDetailPage>(parameters => parameters.Add(p => p.Id, "missing"));

        cut.WaitForAssertion(() => Assert.Contains("Playlist not found", cut.Markup));
    }

    [Fact]
    public void RendersDynamicConfigEditor_InsteadOfManualControls_WhenPlaylistIsDynamic()
    {
        var config = new DynamicPlaylistConfig(["show-1"], 5, ["show-1"]);
        var detail = new PlaylistDetail(
            "playlist-1", "Commute", PlaylistType.Dynamic, [], DateTimeOffset.UtcNow, DateTimeOffset.UtcNow, config);
        var subscription = new Subscription("sub-1", "show-1", "Show One", "Author", null, DateTimeOffset.UtcNow);
        ConfigureApi(new TestHttpMessageHandler(request =>
            request.RequestUri!.AbsolutePath.Contains("subscriptions")
                ? new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(new List<Subscription> { subscription }) }
                : new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(detail) }));

        var cut = RenderComponent<PlaylistDetailPage>(parameters => parameters.Add(p => p.Id, "playlist-1"));

        cut.WaitForAssertion(() =>
        {
            Assert.Contains("Show One", cut.Markup);
            Assert.Contains("Max episodes", cut.Markup);
        });
        Assert.DoesNotContain("Drag episodes to reorder", cut.Markup);
    }

    [Fact]
    public void SavesDynamicConfig_AndRefreshesItems_WhenSaveClicked()
    {
        var config = new DynamicPlaylistConfig(["show-1"], 5, ["show-1"]);
        var initialDetail = new PlaylistDetail(
            "playlist-1", "Commute", PlaylistType.Dynamic, [], DateTimeOffset.UtcNow, DateTimeOffset.UtcNow, config);
        var refreshedDetail = initialDetail with
        {
            Items = [new PlaylistItemDetail("episode-1", "show-1", "Fresh Episode", null, DateTimeOffset.UtcNow, "m")],
        };
        var subscription = new Subscription("sub-1", "show-1", "Show One", "Author", null, DateTimeOffset.UtcNow);

        var detailCallCount = 0;
        ConfigureApi(new TestHttpMessageHandler(request =>
        {
            if (request.RequestUri!.AbsolutePath.Contains("subscriptions"))
            {
                return new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(new List<Subscription> { subscription }) };
            }

            if (request.Method == HttpMethod.Put)
            {
                return new HttpResponseMessage(HttpStatusCode.OK)
                {
                    Content = JsonContent.Create(new Playlist("playlist-1", "Commute", PlaylistType.Dynamic, [], DateTimeOffset.UtcNow, DateTimeOffset.UtcNow, config)),
                };
            }

            detailCallCount++;
            return new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(detailCallCount == 1 ? initialDetail : refreshedDetail) };
        }));

        var cut = RenderComponent<PlaylistDetailPage>(parameters => parameters.Add(p => p.Id, "playlist-1"));
        cut.WaitForAssertion(() => Assert.Contains("Show One", cut.Markup));

        // Selected by text rather than "button.btn-primary" — the "Only unplayed" toggle also
        // renders with btn-primary while active (the default), so a bare class selector would
        // match it instead of the editor's own save button.
        cut.FindAll("button").Single(button => button.TextContent.Contains("Save Changes")).Click();

        cut.WaitForAssertion(() => Assert.Contains("Fresh Episode", cut.Markup));
    }

    [Fact]
    public void HydratesEpisodeStatesAndFiltersToUnplayed_OnInitialLoad()
    {
        var detail = MakeDetail(
            new PlaylistItemDetail("episode-1", "show-1", "Unplayed Episode", null, DateTimeOffset.UtcNow, "m"),
            new PlaylistItemDetail("episode-2", "show-1", "Played Episode", null, DateTimeOffset.UtcNow, "n"));
        var statesFetched = false;
        ConfigureApi(new TestHttpMessageHandler(request =>
        {
            if (request.RequestUri!.AbsolutePath == "/api/playlists/playlist-1" && request.Method == HttpMethod.Get)
            {
                return new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(detail) };
            }

            if (request.RequestUri.AbsolutePath == "/api/episodes/states" && request.Method == HttpMethod.Post)
            {
                statesFetched = true;
                return new HttpResponseMessage(HttpStatusCode.OK)
                {
                    Content = JsonContent.Create(new Dictionary<string, EpisodeState>
                    {
                        ["episode-1"] = new("episode-1", "user-1", "episode-1", "show-1", 0, false, DateTimeOffset.UtcNow, "web", AutoPlayed: false),
                        ["episode-2"] = new("episode-2", "user-1", "episode-2", "show-1", 30, true, DateTimeOffset.UtcNow, "web", AutoPlayed: false),
                    }),
                };
            }

            return new HttpResponseMessage(HttpStatusCode.NotFound);
        }));

        var cut = RenderComponent<PlaylistDetailPage>(parameters => parameters.Add(p => p.Id, "playlist-1"));

        cut.WaitForAssertion(() =>
        {
            Assert.True(statesFetched);
            Assert.Contains("Unplayed Episode", cut.Markup);
            Assert.DoesNotContain("Played Episode", cut.Markup);
            Assert.Contains("2 episodes total", cut.Markup);
        });
    }

    [Fact]
    public void ShowsAllEpisodes_WhenOnlyUnplayedToggleDisabled()
    {
        var detail = MakeDetail(
            new PlaylistItemDetail("episode-1", "show-1", "Unplayed Episode", null, DateTimeOffset.UtcNow, "m"),
            new PlaylistItemDetail("episode-2", "show-1", "Played Episode", null, DateTimeOffset.UtcNow, "n"));
        ConfigureApi(new TestHttpMessageHandler(request =>
        {
            if (request.RequestUri!.AbsolutePath == "/api/playlists/playlist-1" && request.Method == HttpMethod.Get)
            {
                return new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(detail) };
            }

            if (request.RequestUri.AbsolutePath == "/api/episodes/states" && request.Method == HttpMethod.Post)
            {
                return new HttpResponseMessage(HttpStatusCode.OK)
                {
                    Content = JsonContent.Create(new Dictionary<string, EpisodeState>
                    {
                        ["episode-1"] = new("episode-1", "user-1", "episode-1", "show-1", 0, false, DateTimeOffset.UtcNow, "web", AutoPlayed: false),
                        ["episode-2"] = new("episode-2", "user-1", "episode-2", "show-1", 30, true, DateTimeOffset.UtcNow, "web", AutoPlayed: false),
                    }),
                };
            }

            return new HttpResponseMessage(HttpStatusCode.NotFound);
        }));

        var cut = RenderComponent<PlaylistDetailPage>(parameters => parameters.Add(p => p.Id, "playlist-1"));

        // Unplayed-only is the default, so "Played Episode" is hidden until the toggle is switched off.
        cut.WaitForAssertion(() =>
        {
            Assert.Contains("Unplayed Episode", cut.Markup);
            Assert.DoesNotContain("Played Episode", cut.Markup);
            Assert.Contains("shows/show-1/episodes/episode-1", cut.Find("a.btn-primary").GetAttribute("href"));
        });

        cut.FindAll("button").Single(button => button.TextContent.Contains("Showing unplayed only")).Click();

        cut.WaitForAssertion(() =>
        {
            Assert.Contains("Unplayed Episode", cut.Markup);
            Assert.Contains("Played Episode", cut.Markup);
        });
    }

    [Fact]
    public void RefetchesDetail_WhenSyncPollReportsAChangeForThisPlaylist()
    {
        // #113: a dynamic playlist's server-side auto-insertion/eviction (#112) reaches this page
        // through the same poll-and-apply mechanism Settings.razor/NewEpisodes.razor already use
        // (SyncStatusService<T>, #86) — exercises PlaylistDetail's own ApplyServerChanges directly,
        // same rationale/pattern as SettingsTests' equivalent case, rather than re-deriving
        // SyncStatusService's own polling behavior (already covered by SyncStatusServiceTests).
        var initialDetail = MakeDetail(new PlaylistItemDetail("episode-1", "show-1", "Original Episode", null, DateTimeOffset.UtcNow, "m"));
        var refreshedDetail = MakeDetail(
            new PlaylistItemDetail("episode-1", "show-1", "Original Episode", null, DateTimeOffset.UtcNow, "m"),
            new PlaylistItemDetail("episode-2", "show-1", "Auto-Inserted Episode", null, DateTimeOffset.UtcNow, "n"));

        var detailCallCount = 0;
        ConfigureApi(new TestHttpMessageHandler(request =>
        {
            if (request.RequestUri!.AbsolutePath == "/api/sync/playlists")
            {
                return new HttpResponseMessage(HttpStatusCode.OK)
                {
                    Content = JsonContent.Create(new { ServerChanges = Array.Empty<Playlist>(), SyncedAt = DateTimeOffset.UtcNow, Hash = "h1" }),
                };
            }

            if (request.RequestUri.AbsolutePath == "/api/episodes/states" && request.Method == HttpMethod.Post)
            {
                return new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(new Dictionary<string, EpisodeState>()) };
            }

            detailCallCount++;
            return new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(detailCallCount == 1 ? initialDetail : refreshedDetail) };
        }));

        var cut = RenderComponent<PlaylistDetailPage>(parameters => parameters.Add(p => p.Id, "playlist-1"));
        cut.WaitForAssertion(() => Assert.Contains("Original Episode", cut.Markup));
        Assert.DoesNotContain("Auto-Inserted Episode", cut.Markup);

        var remotePlaylist = new Playlist(
            "playlist-1", "Commute", PlaylistType.Manual, [], DateTimeOffset.UtcNow, DateTimeOffset.UtcNow);
        var applyServerChanges = cut.Instance.GetType().GetMethod(
            "ApplyServerChanges", System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance)!;

        cut.InvokeAsync(() => applyServerChanges.Invoke(cut.Instance, [new[] { remotePlaylist }]));

        cut.WaitForAssertion(() => Assert.Contains("Auto-Inserted Episode", cut.Markup));
    }

    [Fact]
    public void ShowsDeletedMessage_WhenSyncPollReportsThisPlaylistTombstoned()
    {
        // #400: a playlist deleted on another device reaches this page as a sync ServerChange with
        // Deleted = true; ApplyServerChanges drops the view rather than re-fetching (the GET would
        // 404).
        var detail = MakeDetail(new PlaylistItemDetail("episode-1", "show-1", "Original Episode", null, DateTimeOffset.UtcNow, "m"));
        ConfigureApi(new TestHttpMessageHandler(request =>
        {
            if (request.RequestUri!.AbsolutePath == "/api/sync/playlists")
            {
                return new HttpResponseMessage(HttpStatusCode.OK)
                {
                    Content = JsonContent.Create(new { ServerChanges = Array.Empty<Playlist>(), SyncedAt = DateTimeOffset.UtcNow, Hash = "h1" }),
                };
            }

            if (request.RequestUri.AbsolutePath == "/api/episodes/states" && request.Method == HttpMethod.Post)
            {
                return new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(new Dictionary<string, EpisodeState>()) };
            }

            return new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(detail) };
        }));

        var cut = RenderComponent<PlaylistDetailPage>(parameters => parameters.Add(p => p.Id, "playlist-1"));
        cut.WaitForAssertion(() => Assert.Contains("Original Episode", cut.Markup));

        var tombstone = new Playlist(
            "playlist-1", "Commute", PlaylistType.Manual, [], DateTimeOffset.UtcNow, DateTimeOffset.UtcNow, Deleted: true);
        var applyServerChanges = cut.Instance.GetType().GetMethod(
            "ApplyServerChanges", System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance)!;

        cut.InvokeAsync(() => applyServerChanges.Invoke(cut.Instance, [new[] { tombstone }]));

        cut.WaitForAssertion(() =>
        {
            Assert.Contains("deleted on another device", cut.Markup);
            Assert.DoesNotContain("Original Episode", cut.Markup);
        });
    }

    [Fact]
    public void RemovesItem_WhenRemoveClicked()
    {
        var item = new PlaylistItemDetail("episode-1", "show-1", "Episode One", null, DateTimeOffset.UtcNow, "m");
        var detail = MakeDetail(item);
        ConfigureApi(new TestHttpMessageHandler(request =>
            request.Method == HttpMethod.Delete
                ? new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(new Playlist("playlist-1", "Commute", PlaylistType.Manual, [], DateTimeOffset.UtcNow, DateTimeOffset.UtcNow)) }
                : new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(detail) }));

        var cut = RenderComponent<PlaylistDetailPage>(parameters => parameters.Add(p => p.Id, "playlist-1"));
        cut.WaitForAssertion(() => Assert.Contains("Episode One", cut.Markup));

        cut.Find("button.btn-outline-danger").Click();

        cut.WaitForAssertion(() => Assert.DoesNotContain("Episode One", cut.Markup));
    }

    [Fact]
    public void EditPanel_RendersPlayNextOverride_AndSendsItWithSave()
    {
        var detail = MakeDetail(new PlaylistItemDetail("ep-1", "show-1", "Monday Edition", null, DateTimeOffset.UtcNow, "m"))
            with { PlayNextBehavior = PlayNextBehavior.TopOfList };
        string? putBody = null;
        ConfigureApi(new TestHttpMessageHandler(request =>
        {
            var path = request.RequestUri!.AbsolutePath;
            if (path == "/api/playlists/playlist-1" && request.Method == HttpMethod.Get)
            {
                return new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(detail) };
            }

            if (path == "/api/playlists/playlist-1" && request.Method == HttpMethod.Put)
            {
                putBody = request.Content!.ReadAsStringAsync().GetAwaiter().GetResult();
                return new HttpResponseMessage(HttpStatusCode.OK)
                {
                    Content = JsonContent.Create(new Playlist(
                        "playlist-1", "Commute", PlaylistType.Manual, [], DateTimeOffset.UtcNow, DateTimeOffset.UtcNow,
                        PlayNextBehavior: PlayNextBehavior.Stop)),
                };
            }

            if (path == "/api/episodes/states" && request.Method == HttpMethod.Post)
            {
                return new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(new Dictionary<string, EpisodeState>()) };
            }

            return new HttpResponseMessage(HttpStatusCode.NotFound);
        }));

        var cut = RenderComponent<PlaylistDetailPage>(parameters => parameters.Add(p => p.Id, "playlist-1"));
        cut.WaitForAssertion(() => Assert.Contains("Edit playlist", cut.Markup));
        cut.FindAll("button").Single(button => button.TextContent.Contains("Edit playlist")).Click();

        // The current override is pre-selected, so a name-only edit round-trips it unchanged.
        cut.WaitForAssertion(() => Assert.Equal("TopOfList", cut.Find("#playlist-play-next").GetAttribute("value")));

        cut.Find("#playlist-play-next").Change("Stop");
        cut.FindAll("button").Single(button => button.TextContent.Trim() == "Save").Click();

        cut.WaitForAssertion(() =>
        {
            Assert.Contains($"\"playNextBehavior\":{(int)PlayNextBehavior.Stop}", putBody);
            Assert.DoesNotContain("Playlist name", cut.Markup);
        });
    }

    [Fact]
    public void EditPanel_ClearsPlayNextOverride_WhenGlobalDefaultIsSelected()
    {
        // Regression coverage for the nullable-enum <select @bind> (unlike every other override
        // picker in this app, which binds via RadioChoice/manual @onchange) — verifies the "Use
        // global default" empty option actually round-trips to a null PUT body rather than
        // silently resending the previously-selected override.
        var detail = MakeDetail(new PlaylistItemDetail("ep-1", "show-1", "Monday Edition", null, DateTimeOffset.UtcNow, "m"))
            with { PlayNextBehavior = PlayNextBehavior.TopOfList };
        string? putBody = null;
        ConfigureApi(new TestHttpMessageHandler(request =>
        {
            var path = request.RequestUri!.AbsolutePath;
            if (path == "/api/playlists/playlist-1" && request.Method == HttpMethod.Get)
            {
                return new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(detail) };
            }

            if (path == "/api/playlists/playlist-1" && request.Method == HttpMethod.Put)
            {
                putBody = request.Content!.ReadAsStringAsync().GetAwaiter().GetResult();
                return new HttpResponseMessage(HttpStatusCode.OK)
                {
                    Content = JsonContent.Create(new Playlist(
                        "playlist-1", "Commute", PlaylistType.Manual, [], DateTimeOffset.UtcNow, DateTimeOffset.UtcNow,
                        PlayNextBehavior: null)),
                };
            }

            if (path == "/api/episodes/states" && request.Method == HttpMethod.Post)
            {
                return new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(new Dictionary<string, EpisodeState>()) };
            }

            return new HttpResponseMessage(HttpStatusCode.NotFound);
        }));

        var cut = RenderComponent<PlaylistDetailPage>(parameters => parameters.Add(p => p.Id, "playlist-1"));
        cut.WaitForAssertion(() => Assert.Contains("Edit playlist", cut.Markup));
        cut.FindAll("button").Single(button => button.TextContent.Contains("Edit playlist")).Click();

        cut.WaitForAssertion(() => Assert.Equal("TopOfList", cut.Find("#playlist-play-next").GetAttribute("value")));

        cut.Find("#playlist-play-next").Change("");
        cut.FindAll("button").Single(button => button.TextContent.Trim() == "Save").Click();

        cut.WaitForAssertion(() => Assert.Contains("\"playNextBehavior\":null", putBody));
    }

    [Fact]
    public void RendersUpNextQueueSettings_InEditPanel_WhenPlaylistIsUpNext()
    {
        var detail = MakeUpNextDetail(new PlaylistItemDetail("ep-1", "show-1", "Monday Edition", null, DateTimeOffset.UtcNow, "m"));
        ConfigureApi(UpNextHandler(detail, settings: new(
            "user-1", UnlistenedEpisodeCount.Five, Version: 1, AutoArchiveRule.Never,
            AutoAddNewEpisodesToUpNext: true, UpNextInsertPosition: UpNextInsertPosition.Top)));

        var cut = RenderComponent<PlaylistDetailPage>(parameters => parameters.Add(p => p.Id, "up-next-1"));
        cut.WaitForAssertion(() => Assert.Contains("Monday Edition", cut.Markup));

        cut.FindAll("button").Single(button => button.TextContent.Contains("Edit playlist")).Click();

        cut.WaitForAssertion(() =>
        {
            Assert.Contains("Queue behaviour", cut.Markup);
            Assert.True(cut.Find("#up-next-auto-add").HasAttribute("checked"));
            Assert.Equal("Top", cut.Find("#up-next-insert-position").GetAttribute("value"));
        });
    }

    [Fact]
    public void DoesNotRenderQueueSettings_WhenPlaylistIsNotUpNext()
    {
        ConfigureApi(TestHttpMessageHandler.Json(MakeDetail()));

        var cut = RenderComponent<PlaylistDetailPage>(parameters => parameters.Add(p => p.Id, "playlist-1"));
        cut.WaitForAssertion(() => Assert.Contains("Edit playlist", cut.Markup));

        cut.FindAll("button").Single(button => button.TextContent.Contains("Edit playlist")).Click();

        cut.WaitForAssertion(() => Assert.Contains("Playlist name", cut.Markup));
        Assert.DoesNotContain("Queue behaviour", cut.Markup);
        Assert.Empty(cut.FindAll("#up-next-auto-add"));
    }

    [Fact]
    public void SavesAndConfirmsAutoAdd_WhenToggledInEditPanel()
    {
        var detail = MakeUpNextDetail();
        string? putPath = null;
        ConfigureApi(UpNextHandler(detail, onSettingsPut: request =>
        {
            putPath = request.RequestUri!.AbsolutePath;
            return new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(DefaultSettings) };
        }));

        var cut = RenderComponent<PlaylistDetailPage>(parameters => parameters.Add(p => p.Id, "up-next-1"));
        cut.WaitForAssertion(() => Assert.Contains("Edit playlist", cut.Markup));
        cut.FindAll("button").Single(button => button.TextContent.Contains("Edit playlist")).Click();

        cut.WaitForAssertion(() => cut.Find("#up-next-auto-add"));
        cut.Find("#up-next-auto-add").Change(true);

        cut.WaitForAssertion(() =>
        {
            Assert.Equal("/api/settings/auto-add-up-next", putPath);
            Assert.Contains("Saved.", cut.Markup);
        });
    }

    [Fact]
    public void SavesAndConfirmsInsertPosition_WhenChangedInEditPanel()
    {
        var detail = MakeUpNextDetail();
        string? putPath = null;
        ConfigureApi(UpNextHandler(detail, onSettingsPut: request =>
        {
            putPath = request.RequestUri!.AbsolutePath;
            return new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(DefaultSettings) };
        }));

        var cut = RenderComponent<PlaylistDetailPage>(parameters => parameters.Add(p => p.Id, "up-next-1"));
        cut.WaitForAssertion(() => Assert.Contains("Edit playlist", cut.Markup));
        cut.FindAll("button").Single(button => button.TextContent.Contains("Edit playlist")).Click();

        cut.WaitForAssertion(() => cut.Find("#up-next-insert-position"));
        cut.Find("#up-next-insert-position").Change("Top");

        cut.WaitForAssertion(() =>
        {
            Assert.Equal("/api/settings/up-next-insert-position", putPath);
            Assert.Contains("Saved.", cut.Markup);
        });
    }

    [Fact]
    public void ShowsErrorAndRevertsAutoAdd_WhenSaveFailsInEditPanel()
    {
        var detail = MakeUpNextDetail();
        ConfigureApi(UpNextHandler(detail, onSettingsPut: _ =>
            new HttpResponseMessage(HttpStatusCode.InternalServerError)));

        var cut = RenderComponent<PlaylistDetailPage>(parameters => parameters.Add(p => p.Id, "up-next-1"));
        cut.WaitForAssertion(() => Assert.Contains("Edit playlist", cut.Markup));
        cut.FindAll("button").Single(button => button.TextContent.Contains("Edit playlist")).Click();

        cut.WaitForAssertion(() => Assert.False(cut.Find("#up-next-auto-add").HasAttribute("checked")));
        cut.Find("#up-next-auto-add").Change(true);

        cut.WaitForAssertion(() =>
        {
            Assert.Contains("Something went wrong", cut.Markup);
            Assert.False(cut.Find("#up-next-auto-add").HasAttribute("checked"));
        });
    }

    [Fact]
    public void DeletesPlaylist_AndNavigatesToList_WhenDeleteConfirmed()
    {
        var detail = MakeDetail();
        string? deletedPath = null;
        ConfigureApi(new TestHttpMessageHandler(request =>
        {
            if (request.Method == HttpMethod.Delete)
            {
                deletedPath = request.RequestUri!.AbsolutePath;
                return new HttpResponseMessage(HttpStatusCode.NoContent);
            }

            return new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(detail) };
        }));

        var navigation = Services.GetRequiredService<FakeNavigationManager>();
        var cut = RenderComponent<PlaylistDetailPage>(parameters => parameters.Add(p => p.Id, "playlist-1"));
        cut.WaitForAssertion(() => Assert.Contains("Delete playlist", cut.Markup));

        cut.FindAll("button").Single(button => button.TextContent.Contains("Delete playlist")).Click();
        cut.FindAll("button").Single(button => button.TextContent.Trim() == "Confirm").Click();

        cut.WaitForAssertion(() =>
        {
            Assert.Equal("/api/playlists/playlist-1", deletedPath);
            Assert.Equal("http://localhost/playlists", navigation.Uri);
        });
    }
}
