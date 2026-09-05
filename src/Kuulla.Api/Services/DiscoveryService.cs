using Kuulla.Api.Models;

namespace Kuulla.Api.Services;

public class DiscoveryService(IShowService showService) : IDiscoveryService
{
    // Apple's top-level podcast genre IDs (https://podcasts.apple.com/us/genre/id{id}), fixed
    // rather than fetched — Apple doesn't expose a genre-listing API, and this set changes rarely
    // enough to just hardcode.
    public static readonly IReadOnlyList<DiscoveryCategory> Categories = new List<DiscoveryCategory>
    {
        new("1301", "Arts"),
        new("1321", "Business"),
        new("1303", "Comedy"),
        new("1304", "Education"),
        new("1511", "Government"),
        new("1512", "Health & Fitness"),
        new("1487", "History"),
        new("1305", "Kids & Family"),
        new("1310", "Music"),
        new("1489", "News"),
        new("1314", "Religion & Spirituality"),
        new("1533", "Science"),
        new("1324", "Society & Culture"),
        new("1545", "Sports"),
        new("1318", "Technology"),
        new("1309", "TV & Film"),
        new("1488", "True Crime"),
    }.AsReadOnly();

    public async Task<DiscoveryOverview> GetOverviewAsync(CancellationToken cancellationToken)
    {
        var trending = await showService.GetTrendingAsync(null, cancellationToken);
        return new DiscoveryOverview(Categories, trending);
    }

    public async Task<CategoryDiscovery?> GetCategoryAsync(string categoryId, CancellationToken cancellationToken)
    {
        var category = Categories.FirstOrDefault(c => c.Id == categoryId);
        if (category is null)
        {
            return null;
        }

        var trending = await showService.GetTrendingAsync(categoryId, cancellationToken);
        return new CategoryDiscovery(category, trending);
    }
}
