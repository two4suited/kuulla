using Kuulla.Api.Models;
using Kuulla.Api.Services;
using Moq;
using Newtonsoft.Json;
using StackExchange.Redis;

namespace Kuulla.Api.Tests;

public class DiscoveryServiceTests
{
    private readonly Mock<IShowService> _showService = new();
    private readonly Mock<IConnectionMultiplexer> _redis = new();
    private readonly Mock<IDatabase> _database = new();
    private readonly DiscoveryService _sut;

    public DiscoveryServiceTests()
    {
        _redis.Setup(r => r.GetDatabase(It.IsAny<int>(), It.IsAny<object>())).Returns(_database.Object);
        _database.Setup(d => d.StringGetAsync(It.IsAny<RedisKey>(), It.IsAny<CommandFlags>())).ReturnsAsync(RedisValue.Null);
        _sut = new DiscoveryService(_showService.Object, _redis.Object);
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
    public async Task GetOverviewAsync_CachesResponseInRedis()
    {
        var shows = new[] { CosmosTestHelpers.MakeShow("1") };
        _showService.Setup(s => s.GetTrendingAsync(null, It.IsAny<CancellationToken>())).ReturnsAsync(shows);

        await _sut.GetOverviewAsync(CancellationToken.None);

        var invocation = Assert.Single(_database.Invocations, i => i.Method.Name == nameof(IDatabaseAsync.StringSetAsync));
        Assert.Equal("discovery:overview", (string)(RedisKey)invocation.Arguments[0]!);
        Assert.Equal((Expiration)TimeSpan.FromHours(6), (Expiration)invocation.Arguments[2]!);
    }

    [Fact]
    public async Task GetOverviewAsync_ReturnsCachedResponseWithoutQueryingShowServiceOnHit()
    {
        var cached = new DiscoveryOverview(DiscoveryService.Categories, [CosmosTestHelpers.MakeShow("1")]);
        _database
            .Setup(d => d.StringGetAsync("discovery:overview", It.IsAny<CommandFlags>()))
            .ReturnsAsync(new RedisValue(JsonConvert.SerializeObject(cached)));

        var overview = await _sut.GetOverviewAsync(CancellationToken.None);

        Assert.Equal(cached.Categories, overview.Categories);
        Assert.Equal(cached.Trending.Select(s => s.Id), overview.Trending.Select(s => s.Id));
        _showService.Verify(s => s.GetTrendingAsync(It.IsAny<string?>(), It.IsAny<CancellationToken>()), Times.Never);
    }

    [Fact]
    public async Task GetOverviewAsync_RecomputesWhenCachedValueIsCorrupted()
    {
        _database
            .Setup(d => d.StringGetAsync("discovery:overview", It.IsAny<CommandFlags>()))
            .ReturnsAsync(new RedisValue("not valid json"));
        var shows = new[] { CosmosTestHelpers.MakeShow("1") };
        _showService.Setup(s => s.GetTrendingAsync(null, It.IsAny<CancellationToken>())).ReturnsAsync(shows);

        var overview = await _sut.GetOverviewAsync(CancellationToken.None);

        Assert.Equal(shows.Select(s => s.Id), overview.Trending.Select(s => s.Id));
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

    [Fact]
    public async Task GetCategoryAsync_ReturnsCachedResponseWithoutQueryingShowServiceOnHit()
    {
        var category = DiscoveryService.Categories[0];
        var cached = new CategoryDiscovery(category, [CosmosTestHelpers.MakeShow("1")]);
        _database
            .Setup(d => d.StringGetAsync($"discovery:category:{category.Id}", It.IsAny<CommandFlags>()))
            .ReturnsAsync(new RedisValue(JsonConvert.SerializeObject(cached)));

        var result = await _sut.GetCategoryAsync(category.Id, CancellationToken.None);

        Assert.Equal(cached.Category, result!.Category);
        Assert.Equal(cached.Trending.Select(s => s.Id), result.Trending.Select(s => s.Id));
        _showService.Verify(s => s.GetTrendingAsync(It.IsAny<string?>(), It.IsAny<CancellationToken>()), Times.Never);
    }
}
