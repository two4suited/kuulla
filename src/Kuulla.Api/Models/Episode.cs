using Newtonsoft.Json;

namespace Kuulla.Api.Models;

// Partitioned by ShowId so that "episodes for a show" — the endpoint's actual access
// pattern — is a single-partition query instead of a cross-partition fan-out.
// Duration/FileSizeBytes/BitrateKbps are nullable because RSS feeds don't reliably
// publish all of them — bitrate in particular is almost never present and is only
// derived when both file size and duration are known.
public record Episode(
    [property: JsonProperty("id")] string Id,
    string ShowId,
    string Title,
    DateTimeOffset? PublishedAt,
    TimeSpan? Duration,
    string AudioUrl,
    string? Description,
    int? BitrateKbps,
    long? FileSizeBytes,
    IReadOnlyList<EpisodeChapter>? Chapters = null,
    // From Podcasting 2.0's <podcast:transcript>. TranscriptType is the tag's declared MIME type
    // (e.g. "application/json", "application/x-subrip", "text/vtt") — kept so the transcript
    // endpoint knows how to parse the document without sniffing.
    string? TranscriptUrl = null,
    string? TranscriptType = null);
