namespace Kuulla.Core.Models;

// The transcript endpoint's response: an ordered list of timed segments plus the source MIME
// type they were normalized from (handy for clients that want to note "transcript provided as
// SRT" and for debugging).
public record TranscriptDocument(
    string? SourceType,
    IReadOnlyList<TranscriptSegment> Segments);
