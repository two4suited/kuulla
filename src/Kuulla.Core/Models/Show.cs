using Newtonsoft.Json;

namespace Kuulla.Core.Models;

public record Show(
    [property: JsonProperty("id")] string Id,
    string Title,
    string Author,
    string FeedUrl,
    string? ArtworkUrl,
    string? Description,
    IReadOnlyList<string> Categories);
