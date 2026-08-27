using System.Security.Cryptography;
using System.Text;
using Kuulla.Api.Models;
using Newtonsoft.Json;
using StackExchange.Redis;

namespace Kuulla.Api.Services;

public class TranscriptService(
    PublicResourceFetcher resourceFetcher,
    IConnectionMultiplexer redis,
    ILogger<TranscriptService> logger) : ITranscriptService
{
    // Transcripts are immutable once a feed publishes them, so this can be long — a week is well
    // clear of any reasonable "I fixed the parser, re-fetch" window without being effectively
    // permanent.
    private static readonly TimeSpan CacheTtl = TimeSpan.FromDays(7);

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

        var db = redis.GetDatabase();
        var cacheKey = $"transcript:v1:{Hash(transcriptUrl)}";

        var cached = await db.StringGetAsync(cacheKey);
        if (cached.HasValue)
        {
            try
            {
                var document = JsonConvert.DeserializeObject<TranscriptDocument>(cached!);
                if (document is not null)
                {
                    return document;
                }
            }
            catch (JsonException ex)
            {
                logger.LogWarning(ex, "Discarding unreadable cached transcript for {CacheKey}", cacheKey);
            }
        }

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
        var segments = TranscriptParsing.Parse(format, content);
        if (segments.Count == 0)
        {
            // Nothing usable — don't cache, so a later parser fix (or a feed that later serves a
            // valid document at the same URL) isn't stuck behind a week-long empty entry.
            logger.LogInformation(
                "podcast:transcript from {TranscriptUrl} (declared type '{DeclaredType}', detected {Format}) yielded no segments",
                fetchableUrl, declaredType, format);
            return null;
        }

        var result = new TranscriptDocument(declaredType, segments);
        await db.StringSetAsync(cacheKey, JsonConvert.SerializeObject(result), CacheTtl);
        return result;
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

    private static string Hash(string value)
    {
        var bytes = SHA256.HashData(Encoding.UTF8.GetBytes(value));
        return Convert.ToHexString(bytes).ToLowerInvariant();
    }
}
