using Kuulla.Web.Components.Pages;
using Kuulla.Web.Models;

namespace Kuulla.Web.Tests.Pages;

public class SearchTests : WebTestContext
{
    [Fact]
    public void RendersResults_WhenSearchSucceeds()
    {
        var shows = new List<Show>
        {
            new("show-1", "The Daily", "NYT", "https://feed", null, null, []),
        };
        ConfigureApi(TestHttpMessageHandler.Json(shows));

        var cut = RenderComponent<Search>();
        cut.Find("input").Change("daily");
        cut.Find("form").Submit();

        cut.WaitForAssertion(() => Assert.Contains("The Daily", cut.Markup));
    }

    [Fact]
    public void ShowsNoResultsMessage_WhenSearchReturnsEmpty()
    {
        ConfigureApi(TestHttpMessageHandler.Json(new List<Show>()));

        var cut = RenderComponent<Search>();
        cut.Find("input").Change("nothing");
        cut.Find("form").Submit();

        cut.WaitForAssertion(() => Assert.Contains("No shows found", cut.Markup));
    }

    [Fact]
    public void ShowsErrorMessage_WhenApiRequestFails()
    {
        ConfigureApi(TestHttpMessageHandler.Status(System.Net.HttpStatusCode.InternalServerError));

        var cut = RenderComponent<Search>();
        cut.Find("input").Change("daily");
        cut.Find("form").Submit();

        cut.WaitForAssertion(() => Assert.Contains("Something went wrong", cut.Markup));
    }

    [Fact]
    public void DoesNotSearch_WhenQueryIsBlank()
    {
        var called = false;
        ConfigureApi(new TestHttpMessageHandler(_ =>
        {
            called = true;
            return new HttpResponseMessage(System.Net.HttpStatusCode.OK);
        }));

        var cut = RenderComponent<Search>();
        cut.Find("form").Submit();

        Assert.False(called);
    }
}
