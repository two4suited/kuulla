using System.Net;
using System.Net.Http.Json;
using Kuulla.Web.Components.Pages;
using Kuulla.Web.Models;

namespace Kuulla.Web.Tests.Pages;

public class ShowDetailTests : WebTestContext
{
    private static readonly Show TestShow = new(
        "show-1", "The Daily", "NYT", "https://feed", null, "A daily news show", []);

    private static readonly Episode TestEpisode = new(
        "ep-1", "show-1", "Monday Edition", DateTimeOffset.UtcNow, TimeSpan.FromMinutes(20), "https://audio", null, null, null);

    private TestHttpMessageHandler CreateHandler(IReadOnlyList<Subscription>? subscriptions = null) =>
        new(request =>
        {
            var path = request.RequestUri!.AbsolutePath;
            if (path == "/api/shows/show-1" && request.Method == HttpMethod.Get)
            {
                return new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(TestShow) };
            }

            if (path == "/api/shows/show-1/episodes" && request.Method == HttpMethod.Get)
            {
                var page = new EpisodePage([TestEpisode], null);
                return new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(page) };
            }

            if (path == "/api/subscriptions" && request.Method == HttpMethod.Get)
            {
                return new HttpResponseMessage(HttpStatusCode.OK)
                {
                    Content = JsonContent.Create(subscriptions ?? []),
                };
            }

            if (path == "/api/subscriptions" && request.Method == HttpMethod.Post)
            {
                var subscription = new Subscription("sub-1", "show-1", "The Daily", "NYT", null, DateTimeOffset.UtcNow);
                return new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(subscription) };
            }

            if (path == "/api/subscriptions/show-1" && request.Method == HttpMethod.Delete)
            {
                return new HttpResponseMessage(HttpStatusCode.OK);
            }

            return new HttpResponseMessage(HttpStatusCode.NotFound);
        });

    [Fact]
    public void RendersShowAndEpisodes_WhenLoadSucceeds()
    {
        ConfigureApi(CreateHandler());

        var cut = RenderComponent<ShowDetail>(parameters => parameters.Add(p => p.Id, "show-1"));

        cut.WaitForAssertion(() =>
        {
            Assert.Contains("The Daily", cut.Markup);
            Assert.Contains("Monday Edition", cut.Markup);
        });
    }

    [Fact]
    public void ShowsNotFoundMessage_WhenShowMissing()
    {
        ConfigureApi(new TestHttpMessageHandler(_ => new HttpResponseMessage(HttpStatusCode.NotFound)));

        var cut = RenderComponent<ShowDetail>(parameters => parameters.Add(p => p.Id, "missing"));

        cut.WaitForAssertion(() => Assert.Contains("Show not found", cut.Markup));
    }

    [Fact]
    public void SubscribeButton_IsHidden_WhenNotAuthenticated()
    {
        ConfigureApi(CreateHandler());

        var cut = RenderComponent<ShowDetail>(parameters => parameters.Add(p => p.Id, "show-1"));

        cut.WaitForAssertion(() => Assert.Contains("The Daily", cut.Markup));
        Assert.DoesNotContain("Subscribe", cut.Markup);
    }

    [Fact]
    public void SubscribesToShow_WhenSubscribeClicked()
    {
        AuthContext.SetAuthorized("test-user");
        ConfigureApi(CreateHandler());

        var cut = RenderComponent<ShowDetail>(parameters => parameters.Add(p => p.Id, "show-1"));
        cut.WaitForAssertion(() => Assert.Contains("Subscribe", cut.Markup));

        cut.Find("button.btn-primary").Click();

        cut.WaitForAssertion(() =>
        {
            Assert.Contains("Unsubscribe", cut.Markup);
            Assert.DoesNotContain("Something went wrong", cut.Markup);
        });
    }
}
