namespace Kuulla.Api.Models;

public record CategoryDiscovery(DiscoveryCategory Category, IReadOnlyList<Show> Trending);
