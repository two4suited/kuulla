using System.Net;
using System.Net.Http.Json;
using Bunit;
using Kuulla.Web.Models;
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
}
