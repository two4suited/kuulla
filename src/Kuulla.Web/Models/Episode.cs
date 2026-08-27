namespace Kuulla.Web.Models;

public record Episode(
    string Id,
    string ShowId,
    string Title,
    DateTimeOffset? PublishedAt,
    TimeSpan? Duration,
    string AudioUrl,
    string? Description,
    int? BitrateKbps,
    long? FileSizeBytes,
    IReadOnlyList<EpisodeChapter>? Chapters = null);

public record EpisodeChapter(
    TimeSpan StartTime,
    string Title,
    string? ImageUrl,
    string? Url);
