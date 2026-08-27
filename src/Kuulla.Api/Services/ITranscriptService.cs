using Kuulla.Api.Models;

namespace Kuulla.Api.Services;

public interface ITranscriptService
{
    // Fetches transcriptUrl and normalizes it into timed segments, regardless of whether the
    // source is a JSON Podcast Transcript, SRT, or VTT. transcriptType is the MIME type the feed
    // declared (used to pick a parser; content sniffing is the fallback). The parsed result is
    // cached — transcripts don't change once published — so repeat requests don't re-fetch.
    // Returns null when there's no usable transcript (unreachable URL, rejected by the SSRF guard,
    // or nothing parseable in the document).
    Task<TranscriptDocument?> GetTranscriptAsync(
        string transcriptUrl, string? transcriptType, CancellationToken cancellationToken);
}
