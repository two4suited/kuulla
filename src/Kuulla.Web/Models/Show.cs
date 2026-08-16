namespace Kuulla.Web.Models;

public record Show(
    string Id,
    string Title,
    string Author,
    string FeedUrl,
    string? ArtworkUrl,
    string? Description,
    IReadOnlyList<string> Categories);
