using Kuulla.Api.Models;

namespace Kuulla.Api.Services;

public interface IDiscoveryService
{
    Task<DiscoveryOverview> GetOverviewAsync(CancellationToken cancellationToken);

    // Returns null when categoryId isn't one of the curated categories.
    Task<CategoryDiscovery?> GetCategoryAsync(string categoryId, CancellationToken cancellationToken);
}
