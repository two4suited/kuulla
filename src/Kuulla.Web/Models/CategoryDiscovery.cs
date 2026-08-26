namespace Kuulla.Web.Models;

public record CategoryDiscovery(DiscoveryCategory Category, IReadOnlyList<Show> Trending);
