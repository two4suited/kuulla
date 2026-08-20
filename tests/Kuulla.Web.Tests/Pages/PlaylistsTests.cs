using System.Net;
using System.Net.Http.Json;
using Bunit;
using Kuulla.Web.Components.Pages;
using Kuulla.Web.Models;

namespace Kuulla.Web.Tests.Pages;

public class PlaylistsTests : WebTestContext
{
    private static readonly List<Playlist> SamplePlaylists =
    [
        new("playlist-1", "Commute", PlaylistType.Manual, [], DateTimeOffset.UtcNow, DateTimeOffset.UtcNow),
    ];

    public PlaylistsTests()
    {
        // DynamicPlaylistConfigEditor.razor.js isn't loadable under bunit's jsdom-less runtime;
        // Loose mode auto-mocks the dynamic import/attach calls (see PlaylistDetailTests).
        JSInterop.Mode = JSRuntimeMode.Loose;
    }

    [Fact]
    public void RendersPlaylists_WhenLoadSucceeds()
    {
        AuthContext.SetAuthorized("user-1");
        ConfigureApi(TestHttpMessageHandler.Json(SamplePlaylists));

        var cut = RenderComponent<Playlists>();

        cut.WaitForAssertion(() => Assert.Contains("Commute", cut.Markup));
    }

    [Fact]
    public void ShowsEmptyMessage_WhenNoPlaylists()
    {
        AuthContext.SetAuthorized("user-1");
        ConfigureApi(TestHttpMessageHandler.Json(new List<Playlist>()));

        var cut = RenderComponent<Playlists>();

        cut.WaitForAssertion(() => Assert.Contains("haven't created", cut.Markup));
    }

    [Fact]
    public void ShowsErrorMessage_WhenLoadFails()
    {
        AuthContext.SetAuthorized("user-1");
        ConfigureApi(TestHttpMessageHandler.Status(HttpStatusCode.InternalServerError));

        var cut = RenderComponent<Playlists>();

        cut.WaitForAssertion(() => Assert.Contains("Something went wrong", cut.Markup));
    }

    [Fact]
    public void AddsPlaylist_WhenCreateSucceeds()
    {
        AuthContext.SetAuthorized("user-1");
        var created = new Playlist("playlist-2", "New Playlist", PlaylistType.Manual, [], DateTimeOffset.UtcNow, DateTimeOffset.UtcNow);
        ConfigureApi(new TestHttpMessageHandler(request =>
            request.Method == HttpMethod.Post && request.RequestUri!.AbsolutePath == "/api/playlists"
                ? new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(created) }
                : new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(new List<Playlist>()) }));

        var cut = RenderComponent<Playlists>();
        cut.WaitForAssertion(() => Assert.Contains("haven't created", cut.Markup));

        cut.Find("input").Input("New Playlist");
        cut.Find("button.btn-primary").Click();

        cut.WaitForAssertion(() => Assert.Contains("New Playlist", cut.Markup));
    }

    [Fact]
    public void ShowsDynamicConfigEditor_OnceNameIsEntered_WhenDynamicSelected()
    {
        AuthContext.SetAuthorized("user-1");
        var subscription = new Subscription("sub-1", "show-1", "Show One", "Author", null, DateTimeOffset.UtcNow);
        ConfigureApi(new TestHttpMessageHandler(request =>
            request.RequestUri!.AbsolutePath.Contains("subscriptions")
                ? new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(new List<Subscription> { subscription }) }
                : new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(new List<Playlist>()) }));

        var cut = RenderComponent<Playlists>();
        cut.WaitForAssertion(() => Assert.Contains("haven't created", cut.Markup));

        cut.FindAll("button").Single(b => b.TextContent.Trim() == "Dynamic").Click();
        Assert.Contains("Enter a name", cut.Markup);

        cut.Find("input").Input("Commute Mix");

        cut.WaitForAssertion(() => Assert.Contains("Max episodes", cut.Markup));
    }

    [Fact]
    public void CreatesDynamicPlaylist_WhenSaveClickedAfterSelectingAShow()
    {
        AuthContext.SetAuthorized("user-1");
        var subscription = new Subscription("sub-1", "show-1", "Show One", "Author", null, DateTimeOffset.UtcNow);
        var created = new Playlist(
            "playlist-2", "Commute Mix", PlaylistType.Dynamic, [], DateTimeOffset.UtcNow, DateTimeOffset.UtcNow,
            new DynamicPlaylistConfig(["show-1"], 20, ["show-1"]));
        ConfigureApi(new TestHttpMessageHandler(request =>
        {
            if (request.RequestUri!.AbsolutePath.Contains("subscriptions"))
            {
                return new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(new List<Subscription> { subscription }) };
            }

            return request.Method == HttpMethod.Post && request.RequestUri!.AbsolutePath == "/api/playlists"
                ? new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(created) }
                : new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(new List<Playlist>()) };
        }));

        var cut = RenderComponent<Playlists>();
        cut.WaitForAssertion(() => Assert.Contains("haven't created", cut.Markup));

        cut.FindAll("button").Single(b => b.TextContent.Trim() == "Dynamic").Click();
        cut.Find("input").Input("Commute Mix");
        cut.WaitForAssertion(() => Assert.Contains("Max episodes", cut.Markup));

        cut.Find("select").Change("show-1");
        cut.FindAll("button").Single(b => b.TextContent.Trim() == "Add").Click();
        cut.WaitForAssertion(() => Assert.Contains("Show One", cut.Markup));

        cut.FindAll("button").Single(b => b.TextContent.Trim() == "Create Dynamic Playlist").Click();

        cut.WaitForAssertion(() => Assert.Contains("Commute Mix", cut.Markup));
    }
}
