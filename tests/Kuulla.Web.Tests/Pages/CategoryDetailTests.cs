using System.Net;
using Kuulla.Web.Components.Pages;
using Kuulla.Web.Models;

namespace Kuulla.Web.Tests.Pages;

public class CategoryDetailTests : WebTestContext
{
    [Fact]
    public void RendersCategoryNameAndTrendingShows_WhenLoadSucceeds()
    {
        var categoryDiscovery = new CategoryDiscovery(
            new DiscoveryCategory("1301", "Arts"),
            [new Show("show-1", "The Daily", "NYT", "https://feed", null, null, [])]);
        ConfigureApi(TestHttpMessageHandler.Json(categoryDiscovery));

        var cut = RenderComponent<CategoryDetail>(parameters => parameters.Add(p => p.CategoryId, "1301"));

        cut.WaitForAssertion(() =>
        {
            Assert.Contains("Arts", cut.Markup);
            Assert.Contains("The Daily", cut.Markup);
        });
    }

    [Fact]
    public void ShowsNotFoundMessage_WhenCategoryMissing()
    {
        ConfigureApi(TestHttpMessageHandler.Status(HttpStatusCode.NotFound));

        var cut = RenderComponent<CategoryDetail>(parameters => parameters.Add(p => p.CategoryId, "missing"));

        cut.WaitForAssertion(() => Assert.Contains("couldn't be found", cut.Markup));
    }

    [Fact]
    public void ShowsErrorMessage_WhenApiRequestFails()
    {
        ConfigureApi(TestHttpMessageHandler.Status(HttpStatusCode.InternalServerError));

        var cut = RenderComponent<CategoryDetail>(parameters => parameters.Add(p => p.CategoryId, "1301"));

        cut.WaitForAssertion(() => Assert.Contains("Something went wrong", cut.Markup));
    }

    [Fact]
    public void ShowsEmptyMessage_WhenCategoryHasNoTrendingShows()
    {
        var categoryDiscovery = new CategoryDiscovery(new DiscoveryCategory("1301", "Arts"), []);
        ConfigureApi(TestHttpMessageHandler.Json(categoryDiscovery));

        var cut = RenderComponent<CategoryDetail>(parameters => parameters.Add(p => p.CategoryId, "1301"));

        cut.WaitForAssertion(() => Assert.Contains("No trending shows in this category", cut.Markup));
    }
}
