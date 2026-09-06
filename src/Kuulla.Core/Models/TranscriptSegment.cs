namespace Kuulla.Core.Models;

// One timed line of a transcript, normalized from whatever source format the feed published
// (JSON Podcast Transcript, SRT, or VTT). EndTime is nullable because some sources (notably
// word-level JSON transcripts) only carry a start time per token.
public record TranscriptSegment(
    TimeSpan StartTime,
    TimeSpan? EndTime,
    string Text);
