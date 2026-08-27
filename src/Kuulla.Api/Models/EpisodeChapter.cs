namespace Kuulla.Api.Models;

// Parsed from a podcast:chapters feed (https://podcastindex.org/namespace/1.0#chapters).
public record EpisodeChapter(
    TimeSpan StartTime,
    string Title,
    string? ImageUrl,
    string? Url);
