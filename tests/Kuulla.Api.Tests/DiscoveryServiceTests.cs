using Kuulla.Api.Services;
using Moq;

namespace Kuulla.Api.Tests;

public class DiscoveryServiceTests
{
    private readonly Mock<IShowService> _showService = new();
    private readonly DiscoveryService _sut;

    public DiscoveryServiceTests()
    {
        _sut = new DiscoveryService(_showService.Object);
    }

    [Fact]
    public async Task GetOverviewAsync_ReturnsCuratedCategoriesAndTrendingShows()
    {
        var shows = new[] { CosmosTestHelpers.MakeShow("1"), CosmosTestHelpers.MakeShow("2") };
        _showService.Setup(s => s.GetTrendingAsync(null, It.IsAny<CancellationToken>())).ReturnsAsync(shows);

        var overview = await _sut.GetOverviewAsync(CancellationToken.None);

        Assert.Equal(DiscoveryService.Categories, overview.Categories);
        Assert.Equal(shows, overview.Trending);
    }

    [Fact]
    public async Task GetCategoryAsync_ReturnsNullForUnknownCategory()
    {
        var result = await _sut.GetCategoryAsync("not-a-real-category", CancellationToken.None);

        Assert.Null(result);
        _showService.Verify(s => s.GetTrendingAsync(It.IsAny<string?>(), It.IsAny<CancellationToken>()), Times.Never);
    }

    [Fact]
    public async Task GetCategoryAsync_ReturnsTrendingShowsForKnownCategory()
    {
        var category = DiscoveryService.Categories[0];
        var shows = new[] { CosmosTestHelpers.MakeShow("1") };
        _showService.Setup(s => s.GetTrendingAsync(category.Id, It.IsAny<CancellationToken>())).ReturnsAsync(shows);

        var result = await _sut.GetCategoryAsync(category.Id, CancellationToken.None);

        Assert.Equal(category, result!.Category);
        Assert.Equal(shows, result.Trending);
    }
}
