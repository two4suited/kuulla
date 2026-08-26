namespace Kuulla.Api.Models;

public record DiscoveryOverview(IReadOnlyList<DiscoveryCategory> Categories, IReadOnlyList<Show> Trending);
