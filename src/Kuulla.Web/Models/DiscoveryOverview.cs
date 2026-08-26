namespace Kuulla.Web.Models;

public record DiscoveryOverview(IReadOnlyList<DiscoveryCategory> Categories, IReadOnlyList<Show> Trending);
