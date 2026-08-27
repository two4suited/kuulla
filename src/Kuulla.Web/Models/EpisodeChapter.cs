namespace Kuulla.Web.Models;

public record EpisodeChapter(
    TimeSpan StartTime,
    string Title,
    string? ImageUrl,
    string? Url);
