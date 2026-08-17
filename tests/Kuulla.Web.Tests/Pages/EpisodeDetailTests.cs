using System.Net;
using Kuulla.Web.Components.Pages;
using Kuulla.Web.Models;

namespace Kuulla.Web.Tests.Pages;

public class EpisodeDetailTests : WebTestContext
{
    private static readonly Episode TestEpisode = new(
        "ep-1", "show-1", "Monday Edition", DateTimeOffset.UtcNow, TimeSpan.FromMinutes(20),
        "https://audio", "Show notes here", 128, 1024);

    [Fact]
    public void RendersEpisode_WhenLoadSucceeds()
    {
        ConfigureApi(TestHttpMessageHandler.Json(TestEpisode));

        var cut = RenderComponent<EpisodeDetail>(parameters => parameters
            .Add(p => p.ShowId, "show-1")
            .Add(p => p.EpisodeId, "ep-1"));

        cut.WaitForAssertion(() =>
        {
            Assert.Contains("Monday Edition", cut.Markup);
            Assert.Contains("Show notes here", cut.Markup);
        });
    }

    [Fact]
    public void ShowsNotFoundMessage_WhenEpisodeMissing()
    {
        ConfigureApi(TestHttpMessageHandler.Status(HttpStatusCode.NotFound));

        var cut = RenderComponent<EpisodeDetail>(parameters => parameters
            .Add(p => p.ShowId, "show-1")
            .Add(p => p.EpisodeId, "missing"));

        cut.WaitForAssertion(() => Assert.Contains("Episode not found", cut.Markup));
    }

    [Fact]
    public void ShowsErrorMessage_WhenApiRequestFails()
    {
        ConfigureApi(TestHttpMessageHandler.Status(HttpStatusCode.InternalServerError));

        var cut = RenderComponent<EpisodeDetail>(parameters => parameters
            .Add(p => p.ShowId, "show-1")
            .Add(p => p.EpisodeId, "ep-1"));

        cut.WaitForAssertion(() => Assert.Contains("Something went wrong", cut.Markup));
    }
}
