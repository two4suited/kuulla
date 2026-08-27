namespace Kuulla.Web.Models;

public record TranscriptSegment(
    TimeSpan StartTime,
    TimeSpan? EndTime,
    string Text);
