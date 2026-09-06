namespace Kuulla.Core.Models;

// Id is an iTunes podcast genre ID (see DiscoveryService.Categories for the curated list).
public record DiscoveryCategory(string Id, string Name);
