using System.Net;
using System.Net.Http.Json;
using Kuulla.Web.Components.Pages;
using Kuulla.Web.Models;
using Microsoft.JSInterop;

namespace Kuulla.Web.Tests.Pages;

public class SubscriptionsTests : WebTestContext
{
    public SubscriptionsTests()
    {
        // Subscriptions hosts <ShowDisplaySettings>, which reads the "showIconSize" localStorage key
        // via JS interop on first render. Loose mode auto-stubs that (returns null → default size).
        JSInterop.Mode = JSRuntimeMode.Loose;
    }

    private static readonly List<Subscription> Subscriptions =
    [
        new("sub-1", "show-1", "The Daily", "NYT", null, DateTimeOffset.UtcNow),
    ];

    private static readonly List<NewEpisode> NewEpisodes =
    [
        new(new Episode("ep-1", "show-1", "Monday Edition", DateTimeOffset.UtcNow, TimeSpan.FromMinutes(20), "https://audio", null, 128, 1024), AutoPlayed: false, ShowTitle: "The Daily", ShowArtworkUrl: "https://art/show-1.jpg"),
    ];

    private static TestHttpMessageHandler RouteHandler(
        Func<HttpRequestMessage, HttpResponseMessage>? onGetSubscriptions = null,
        Func<HttpRequestMessage, HttpResponseMessage>? onGetNewEpisodes = null,
        Func<HttpRequestMessage, HttpResponseMessage>? onGetInProgress = null,
        Func<HttpRequestMessage, HttpResponseMessage>? onDelete = null,
        Func<HttpRequestMessage, HttpResponseMessage>? onGetSettings = null,
        Func<HttpRequestMessage, HttpResponseMessage>? onPutSortOrder = null,
        Func<HttpRequestMessage, HttpResponseMessage>? onPutManualOrder = null,
        Func<HttpRequestMessage, HttpResponseMessage>? onImport = null,
        Func<HttpRequestMessage, HttpResponseMessage>? onExport = null) => new(request =>
    {
        if (request.RequestUri!.AbsolutePath == "/api/subscriptions/import" && request.Method == HttpMethod.Post)
        {
            return onImport?.Invoke(request) ??
                new HttpResponseMessage(HttpStatusCode.OK)
                {
                    Content = JsonContent.Create(new { added = 0, alreadySubscribed = 0, failed = Array.Empty<object>() }),
                };
        }

        if (request.RequestUri.AbsolutePath == "/api/subscriptions/export" && request.Method == HttpMethod.Get)
        {
            return onExport?.Invoke(request) ??
                new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("<opml version=\"2.0\"><body/></opml>") };
        }

        if (request.RequestUri!.AbsolutePath == "/api/settings/subscription-sort-order" && request.Method == HttpMethod.Put)
        {
            return onPutSortOrder?.Invoke(request) ??
                new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(new { subscriptionSortOrder = 0, version = 2 }) };
        }

        if (request.RequestUri.AbsolutePath == "/api/settings/subscription-manual-order" && request.Method == HttpMethod.Put)
        {
            return onPutManualOrder?.Invoke(request) ??
                new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(new { subscriptionSortOrder = 3, version = 2 }) };
        }

        if (request.RequestUri.AbsolutePath == "/api/settings" && request.Method == HttpMethod.Get)
        {
            return onGetSettings?.Invoke(request) ??
                new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(new { subscriptionSortOrder = 0, version = 1 }) };
        }

        if (request.Method == HttpMethod.Delete)
        {
            return onDelete?.Invoke(request) ?? new HttpResponseMessage(HttpStatusCode.OK);
        }

        if (request.RequestUri.AbsolutePath == "/api/episodes/in-progress-shows" && request.Method == HttpMethod.Get)
        {
            return onGetInProgress?.Invoke(request) ??
                new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(Array.Empty<string>()) };
        }

        if (request.RequestUri.AbsolutePath == "/api/subscriptions" && request.Method == HttpMethod.Get)
        {
            return onGetSubscriptions?.Invoke(request) ??
                new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(Subscriptions) };
        }

        if (request.RequestUri.AbsolutePath == "/api/subscriptions/episodes" && request.Method == HttpMethod.Get)
        {
            return onGetNewEpisodes?.Invoke(request) ??
                new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(NewEpisodes) };
        }

        return new HttpResponseMessage(HttpStatusCode.NotFound);
    });

    [Fact]
    public void RendersSubscriptions_WhenLoadSucceeds()
    {
        AuthContext.SetAuthorized("user-1");
        ConfigureApi(RouteHandler());

        var cut = RenderComponent<Subscriptions>();

        cut.WaitForAssertion(() => Assert.Contains("The Daily", cut.Markup));
    }

    [Fact]
    public void ShowsUnplayedBadge_ForShowWithNewEpisodes()
    {
        AuthContext.SetAuthorized("user-1");
        ConfigureApi(RouteHandler());

        var cut = RenderComponent<Subscriptions>();

        cut.WaitForAssertion(() => Assert.Contains("badge", cut.Markup));
    }

    [Fact]
    public void ShowsInProgressBadge_ForShowWithInProgressEpisode()
    {
        AuthContext.SetAuthorized("user-1");
        ConfigureApi(RouteHandler(onGetInProgress: _ =>
            new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(new[] { "show-1" }) }));

        var cut = RenderComponent<Subscriptions>();

        cut.WaitForAssertion(() => Assert.Contains("In progress", cut.Markup));
    }

    [Fact]
    public void RendersSubscriptionsWithoutBadges_WhenUnplayedCountLoadFails()
    {
        AuthContext.SetAuthorized("user-1");
        ConfigureApi(RouteHandler(onGetNewEpisodes: _ => new HttpResponseMessage(HttpStatusCode.InternalServerError)));

        var cut = RenderComponent<Subscriptions>();

        cut.WaitForAssertion(() =>
        {
            Assert.Contains("The Daily", cut.Markup);
            Assert.DoesNotContain("Something went wrong", cut.Markup);
            Assert.DoesNotContain("badge", cut.Markup);
        });
    }

    [Fact]
    public void ShowsEmptyMessage_WhenNoSubscriptions()
    {
        AuthContext.SetAuthorized("user-1");
        ConfigureApi(RouteHandler(onGetSubscriptions: _ => new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(new List<Subscription>()) }));

        var cut = RenderComponent<Subscriptions>();

        cut.WaitForAssertion(() => Assert.Contains("haven't subscribed", cut.Markup));
    }

    [Fact]
    public void ShowsErrorMessage_WhenLoadFails()
    {
        AuthContext.SetAuthorized("user-1");
        ConfigureApi(RouteHandler(onGetSubscriptions: _ => new HttpResponseMessage(HttpStatusCode.InternalServerError)));

        var cut = RenderComponent<Subscriptions>();

        cut.WaitForAssertion(() => Assert.Contains("Something went wrong", cut.Markup));
    }

    [Fact]
    public void RendersSortControl_WithPersistedSelection()
    {
        AuthContext.SetAuthorized("user-1");
        ConfigureApi(RouteHandler(
            onGetSettings: _ => new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = JsonContent.Create(new { subscriptionSortOrder = 2, version = 3 }),
            }));

        var cut = RenderComponent<Subscriptions>();

        // Open the gear popover, then the persisted sort option carries the active marker.
        cut.WaitForAssertion(() => cut.Find("button[aria-label='Display settings']").Click());
        cut.WaitForAssertion(() =>
        {
            var active = cut.Find(".sort-option.active");
            Assert.Contains("Recently added", active.TextContent);
        });
    }

    [Fact]
    public void PersistsSortChoice_WhenSortControlChanged()
    {
        AuthContext.SetAuthorized("user-1");
        string? putBody = null;
        ConfigureApi(RouteHandler(onPutSortOrder: request =>
        {
            putBody = request.Content!.ReadAsStringAsync().Result;
            return new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = JsonContent.Create(new { subscriptionSortOrder = 1, version = 2 }),
            };
        }));

        var cut = RenderComponent<Subscriptions>();
        cut.WaitForAssertion(() => cut.Find("button[aria-label='Display settings']").Click());

        cut.WaitForAssertion(() =>
            cut.FindAll(".sort-option").Single(b => b.TextContent.Contains("Latest episode")).Click());

        cut.WaitForAssertion(() => Assert.Contains("1", putBody ?? ""));
    }

    [Fact]
    public void ShowsDragHint_WhenManualSortActive()
    {
        AuthContext.SetAuthorized("user-1");
        ConfigureApi(RouteHandler(onGetSettings: _ => new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = JsonContent.Create(new { subscriptionSortOrder = 3, version = 1 }),
        }));

        var cut = RenderComponent<Subscriptions>();

        cut.WaitForAssertion(() => Assert.Contains("Drag a show to reorder", cut.Markup));
    }

    [Fact]
    public void PersistsManualOrder_WhenShowDraggedToNewPosition()
    {
        AuthContext.SetAuthorized("user-1");
        var subs = new List<Subscription>
        {
            new("s1", "s1", "Alpha", "A", null, DateTimeOffset.UtcNow),
            new("s2", "s2", "Bravo", "B", null, DateTimeOffset.UtcNow),
            new("s3", "s3", "Charlie", "C", null, DateTimeOffset.UtcNow),
        };
        string? putBody = null;
        ConfigureApi(RouteHandler(
            onGetSubscriptions: _ => new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(subs) },
            onGetSettings: _ => new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = JsonContent.Create(new { subscriptionSortOrder = 3, version = 1 }),
            },
            onPutManualOrder: request =>
            {
                putBody = request.Content!.ReadAsStringAsync().Result;
                return new HttpResponseMessage(HttpStatusCode.OK)
                {
                    Content = JsonContent.Create(new { subscriptionSortOrder = 3, version = 2 }),
                };
            }));

        var cut = RenderComponent<Subscriptions>();
        cut.WaitForAssertion(() => Assert.Equal(3, cut.FindAll(".col").Count));

        // Drag "Charlie" (index 2) onto "Alpha" (index 0). Re-find between the two events —
        // ondragstart mutates state and re-renders, invalidating the earlier element handles.
        cut.InvokeAsync(() =>
            cut.FindAll(".col").ToArray()[2].TriggerEvent("ondragstart", new Microsoft.AspNetCore.Components.Web.DragEventArgs()));
        cut.InvokeAsync(() =>
            cut.FindAll(".col").ToArray()[0].TriggerEvent("ondrop", new Microsoft.AspNetCore.Components.Web.DragEventArgs()));

        cut.WaitForAssertion(() =>
        {
            Assert.NotNull(putBody);
            var s3 = putBody!.IndexOf("s3", StringComparison.Ordinal);
            var s1 = putBody.IndexOf("s1", StringComparison.Ordinal);
            var s2 = putBody.IndexOf("s2", StringComparison.Ordinal);
            Assert.True(s3 >= 0 && s3 < s1 && s1 < s2, $"expected order s3,s1,s2 in: {putBody}");
        });
    }

    [Fact]
    public void GridTiles_AreArtworkOnly_NoTitleOrAuthorOrUnsubscribe()
    {
        AuthContext.SetAuthorized("user-1");
        var subs = new List<Subscription>
        {
            new("sub-1", "show-1", "The Daily", "The New York Times", "https://art/show-1.jpg", DateTimeOffset.UtcNow),
        };
        ConfigureApi(RouteHandler(
            onGetSubscriptions: _ => new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(subs) }));

        var cut = RenderComponent<Subscriptions>();

        cut.WaitForAssertion(() =>
        {
            // Artwork carries the title as its alt text and is the only thing in the tile.
            var img = cut.Find(".col img.card-img");
            Assert.Equal("The Daily", img.GetAttribute("alt"));
            Assert.Empty(cut.FindAll(".col .card-title"));
            Assert.DoesNotContain("The New York Times", cut.Markup);
            Assert.DoesNotContain("Unsubscribe", cut.Markup);
        });
    }

    [Fact]
    public void OpmlImport_ShowsSummary_AndRefreshesGrid_OnSuccess()
    {
        AuthContext.SetAuthorized("user-1");
        var getSubscriptionsCalls = 0;
        ConfigureApi(RouteHandler(
            onGetSubscriptions: _ =>
            {
                getSubscriptionsCalls++;
                var list = getSubscriptionsCalls == 1
                    ? Subscriptions
                    : [.. Subscriptions, new Subscription("sub-2", "show-2", "Reply All", "Gimlet", null, DateTimeOffset.UtcNow)];
                return new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(list) };
            },
            onImport: _ => new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = JsonContent.Create(new
                {
                    added = 1,
                    alreadySubscribed = 2,
                    failed = new[] { new { feedUrl = "https://dead.example/feed", reason = "The feed couldn't be fetched or read." } },
                }),
            }));

        var cut = RenderComponent<Subscriptions>();
        cut.WaitForAssertion(() => Assert.Contains("Import OPML", cut.Markup));

        cut.FindComponent<Microsoft.AspNetCore.Components.Forms.InputFile>()
            .UploadFiles(InputFileContent.CreateFromText("<opml version=\"2.0\"><body/></opml>", "subs.opml"));

        cut.WaitForAssertion(() =>
        {
            Assert.Contains("Added 1, skipped 2 already subscribed, 1 failed.", cut.Markup);
            Assert.Contains("Reply All", cut.Markup);
        });

        cut.Find("button.btn-link").Click();
        cut.WaitForAssertion(() => Assert.Contains("https://dead.example/feed", cut.Markup));
    }

    [Fact]
    public void OpmlImport_ShowsFriendlyError_When400()
    {
        AuthContext.SetAuthorized("user-1");
        ConfigureApi(RouteHandler(
            onImport: _ => new HttpResponseMessage(HttpStatusCode.BadRequest)));

        var cut = RenderComponent<Subscriptions>();
        cut.WaitForAssertion(() => Assert.Contains("Import OPML", cut.Markup));

        cut.FindComponent<Microsoft.AspNetCore.Components.Forms.InputFile>()
            .UploadFiles(InputFileContent.CreateFromText("not opml", "subs.txt"));

        cut.WaitForAssertion(() => Assert.Contains("couldn't be read as an OPML", cut.Markup));
    }

    [Fact]
    public void OpmlExport_HandsBytesToTheBrowserDownloadHelper_OnSuccess()
    {
        AuthContext.SetAuthorized("user-1");
        ConfigureApi(RouteHandler(onExport: _ => new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new StringContent("<opml version=\"2.0\"><body><outline type=\"rss\" xmlUrl=\"https://a.example/feed\" /></body></opml>"),
        }));

        var cut = RenderComponent<Subscriptions>();
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
    public void OpmlExport_ButtonDisabled_WhenNoSubscriptions()
    {
        AuthContext.SetAuthorized("user-1");
        ConfigureApi(RouteHandler(onGetSubscriptions: _ =>
            new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(new List<Subscription>()) }));

        var cut = RenderComponent<Subscriptions>();

        cut.WaitForAssertion(() =>
        {
            var exportButton = cut.FindAll("button").Single(b => b.TextContent.Trim() == "Export OPML");
            Assert.True(exportButton.HasAttribute("disabled"));
        });
    }

    [Fact]
    public void OpmlExport_ShowsFriendlyError_OnFailure()
    {
        AuthContext.SetAuthorized("user-1");
        ConfigureApi(RouteHandler(onExport: _ => new HttpResponseMessage(HttpStatusCode.InternalServerError)));

        var cut = RenderComponent<Subscriptions>();
        cut.WaitForAssertion(() => Assert.Contains("Export OPML", cut.Markup));

        cut.FindAll("button").Single(b => b.TextContent.Trim() == "Export OPML").Click();

        cut.WaitForAssertion(() => Assert.Contains("went wrong exporting", cut.Markup));
    }
}
