namespace Kuulla.Web.Models;

public record TranscriptDocument(
    string? SourceType,
    IReadOnlyList<TranscriptSegment> Segments);
