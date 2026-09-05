using System.Text;
using Kuulla.Api.Models;

namespace Kuulla.Api.Services;

public class TranscriptService(
    PublicResourceFetcher resourceFetcher,
    ILogger<TranscriptService> logger) : ITranscriptService
{
    // A hostile or misconfigured server could stream an unbounded body; 16 MiB is far more than
    // any real episode transcript (a 3-hour word-level JSON transcript is ~1-2 MiB) while still
    // bounding memory.
    private const int MaxTranscriptBytes = 16 * 1024 * 1024;

    public async Task<TranscriptDocument?> GetTranscriptAsync(
        string transcriptUrl, string? transcriptType, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(transcriptUrl))
        {
            return null;
        }

        return await FetchAndParseAsync(transcriptUrl, transcriptType, cancellationToken);
    }

    private async Task<TranscriptDocument?> FetchAndParseAsync(
        string transcriptUrl, string? transcriptType, CancellationToken cancellationToken)
    {
        var fetchableUrl = await resourceFetcher.ResolveFetchableUrlAsync(transcriptUrl, cancellationToken);
        if (fetchableUrl is null)
        {
            return null;
        }

        using var response = await resourceFetcher.SendAsync(fetchableUrl, "podcast:transcript", cancellationToken);
        if (response is null)
        {
            return null;
        }

        string content;
        try
        {
            content = await ReadBoundedStringAsync(response, cancellationToken);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            logger.LogWarning(ex, "Failed to read podcast:transcript body from {TranscriptUrl}", fetchableUrl);
            return null;
        }

        var declaredType = transcriptType ?? response.Content.Headers.ContentType?.MediaType;
        var format = TranscriptParsing.DetectFormat(declaredType, content);

        IReadOnlyList<TranscriptSegment> segments;
        try
        {
            segments = TranscriptParsing.Parse(format, content);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            // Transcript content is untrusted — a parser edge case must degrade to "no transcript"
            // (404), never a 500.
            logger.LogWarning(ex, "Failed to parse podcast:transcript from {TranscriptUrl}", fetchableUrl);
            return null;
        }

        if (segments.Count == 0)
        {
            logger.LogInformation(
                "podcast:transcript from {TranscriptUrl} (declared type '{DeclaredType}', detected {Format}) yielded no segments",
                fetchableUrl, declaredType, format);
            return null;
        }

        return new TranscriptDocument(declaredType, segments);
    }

    private static async Task<string> ReadBoundedStringAsync(HttpResponseMessage response, CancellationToken cancellationToken)
    {
        if (response.Content.Headers.ContentLength is > MaxTranscriptBytes)
        {
            throw new InvalidOperationException(
                $"Transcript body is {response.Content.Headers.ContentLength} bytes, over the {MaxTranscriptBytes}-byte limit.");
        }

        await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken);
        using var limited = new MemoryStream();
        var buffer = new byte[81920];
        int read;
        while ((read = await stream.ReadAsync(buffer, cancellationToken)) > 0)
        {
            if (limited.Length + read > MaxTranscriptBytes)
            {
                throw new InvalidOperationException($"Transcript body exceeded the {MaxTranscriptBytes}-byte limit while streaming.");
            }

            limited.Write(buffer, 0, read);
        }

        return Encoding.UTF8.GetString(limited.GetBuffer(), 0, (int)limited.Length);
    }
}
