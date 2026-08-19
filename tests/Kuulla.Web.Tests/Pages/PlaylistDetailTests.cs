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

        cut.WaitForAssertion(() => Assert.Contains("This playlist is empty", cut.Markup));
    }

    [Fact]
    public void ShowsNotFoundMessage_WhenPlaylistDoesNotExist()
    {
        ConfigureApi(TestHttpMessageHandler.Status(HttpStatusCode.NotFound));

        var cut = RenderComponent<PlaylistDetailPage>(parameters => parameters.Add(p => p.Id, "missing"));

        cut.WaitForAssertion(() => Assert.Contains("Playlist not found", cut.Markup));
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
