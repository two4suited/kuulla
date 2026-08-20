using System.Net;
using System.Net.Http.Json;
using Bunit;
using Kuulla.Web.Components.Pages;
using Kuulla.Web.Models;

namespace Kuulla.Web.Tests.Pages;

public class UpNextTests : WebTestContext
{
    public UpNextTests()
    {
        // The embedded PlaylistDetail component loads PlaylistDetail.razor.js, which isn't
        // loadable under bunit's jsdom-less runtime; Loose mode auto-mocks the dynamic import.
        JSInterop.Mode = JSRuntimeMode.Loose;
    }

    private static readonly Playlist ExistingUpNext = new(
        "up-next-1", "Up Next", PlaylistType.Manual, [new("ep-1", "show-1", DateTimeOffset.UtcNow, "m")], DateTimeOffset.UtcNow, DateTimeOffset.UtcNow);

    private static readonly Kuulla.Web.Models.PlaylistDetail ExistingUpNextDetail = new(
        "up-next-1", "Up Next", PlaylistType.Manual,
        [new PlaylistItemDetail("ep-1", "show-1", "Monday Edition", null, DateTimeOffset.UtcNow, "m")],
        DateTimeOffset.UtcNow, DateTimeOffset.UtcNow);

    private TestHttpMessageHandler CreateHandler(
        IReadOnlyList<Playlist>? playlists = null,
        Func<HttpRequestMessage, HttpResponseMessage>? onCreate = null,
        Func<HttpRequestMessage, HttpResponseMessage>? onGetDetail = null) => new(request =>
    {
        var path = request.RequestUri!.AbsolutePath;
        if (path == "/api/playlists" && request.Method == HttpMethod.Get)
        {
            return new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(playlists ?? []) };
        }

        if (path == "/api/playlists" && request.Method == HttpMethod.Post)
        {
            return onCreate?.Invoke(request) ??
                new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(ExistingUpNext) };
        }

        if (path == "/api/playlists/up-next-1" && request.Method == HttpMethod.Get)
        {
            return onGetDetail?.Invoke(request) ??
                new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(ExistingUpNextDetail) };
        }

        return new HttpResponseMessage(HttpStatusCode.NotFound);
    });

    [Fact]
    public void RendersExistingUpNextPlaylist_WhenOneAlreadyExists()
    {
        AuthContext.SetAuthorized("user-1");
        ConfigureApi(CreateHandler(playlists: [ExistingUpNext]));

        var cut = RenderComponent<UpNext>();

        cut.WaitForAssertion(() =>
        {
            Assert.Contains("Monday Edition", cut.Markup);
            Assert.Contains("Auto-add", cut.Markup);
        });
    }

    [Fact]
    public void CreatesUpNextPlaylist_WhenNoneExistsYet()
    {
        AuthContext.SetAuthorized("user-1");
        var createCalled = false;
        ConfigureApi(CreateHandler(
            playlists: [],
            onCreate: _ =>
            {
                createCalled = true;
                return new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(ExistingUpNext) };
            }));

        var cut = RenderComponent<UpNext>();

        cut.WaitForAssertion(() => Assert.Contains("Monday Edition", cut.Markup));
        Assert.True(createCalled);
    }

    [Fact]
    public void DoesNotCreateAnotherPlaylist_WhenUpNextAlreadyExistsAmongOthers()
    {
        AuthContext.SetAuthorized("user-1");
        var otherPlaylist = new Playlist("other-1", "Weekend Listening", PlaylistType.Manual, [], DateTimeOffset.UtcNow, DateTimeOffset.UtcNow);
        var createCalled = false;
        ConfigureApi(CreateHandler(
            playlists: [otherPlaylist, ExistingUpNext],
            onCreate: _ =>
            {
                createCalled = true;
                return new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(ExistingUpNext) };
            }));

        var cut = RenderComponent<UpNext>();

        cut.WaitForAssertion(() => Assert.Contains("Monday Edition", cut.Markup));
        Assert.False(createCalled);
    }

    [Fact]
    public void ShowsSignInPrompt_WhenNotAuthenticated()
    {
        ConfigureApi(CreateHandler());

        var cut = RenderComponent<UpNext>();

        cut.WaitForAssertion(() => Assert.Contains("log in", cut.Markup));
    }

    [Fact]
    public void ShowsErrorMessage_WhenResolvingPlaylistsFails()
    {
        AuthContext.SetAuthorized("user-1");
        ConfigureApi(TestHttpMessageHandler.Status(HttpStatusCode.InternalServerError));

        var cut = RenderComponent<UpNext>();

        cut.WaitForAssertion(() => Assert.Contains("Something went wrong", cut.Markup));
    }
}
