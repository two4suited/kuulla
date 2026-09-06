namespace Kuulla.Core.Models;

public record DiscoveryOverview(IReadOnlyList<DiscoveryCategory> Categories, IReadOnlyList<Show> Trending);
