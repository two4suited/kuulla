using System.Net;
using System.Net.Http.Json;
using Kuulla.Web.Components.Pages;
using Kuulla.Web.Models;

namespace Kuulla.Web.Tests.Pages;

public class PlaylistsTests : WebTestContext
{
    private static readonly List<Playlist> SamplePlaylists =
    [
        new("playlist-1", "Commute", PlaylistType.Manual, [], DateTimeOffset.UtcNow, DateTimeOffset.UtcNow),
    ];

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
}
