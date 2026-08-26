using Kuulla.Web.Components.Pages;
using Kuulla.Web.Models;

namespace Kuulla.Web.Tests.Pages;

public class DiscoveryTests : WebTestContext
{
    [Fact]
    public void RendersTrendingShowsAndCategories_WhenLoadSucceeds()
    {
        var overview = new DiscoveryOverview(
            [new DiscoveryCategory("1301", "Arts")],
            [new Show("show-1", "The Daily", "NYT", "https://feed", null, null, [])]);
        ConfigureApi(TestHttpMessageHandler.Json(overview));

        var cut = RenderComponent<Discovery>();

        cut.WaitForAssertion(() =>
        {
            Assert.Contains("The Daily", cut.Markup);
            Assert.Contains("Arts", cut.Markup);
        });
    }

    [Fact]
    public void LinksCategoryToCategoryDetailPage()
    {
        var overview = new DiscoveryOverview([new DiscoveryCategory("1301", "Arts")], []);
        ConfigureApi(TestHttpMessageHandler.Json(overview));

        var cut = RenderComponent<Discovery>();

        cut.WaitForAssertion(() =>
            Assert.Equal("discover/categories/1301", cut.Find("a.list-group-item").GetAttribute("href")));
    }

    [Fact]
    public void ShowsErrorMessage_WhenApiRequestFails()
    {
        ConfigureApi(TestHttpMessageHandler.Status(System.Net.HttpStatusCode.InternalServerError));

        var cut = RenderComponent<Discovery>();

        cut.WaitForAssertion(() => Assert.Contains("Something went wrong", cut.Markup));
    }
}
