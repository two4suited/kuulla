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

    // A "no usable transcript" outcome (unreachable, rejected by the SSRF guard, or nothing
    // parseable) is cached too, but only briefly. This endpoint is unauthenticated, so without a
    // negative entry an anonymous caller could make every request re-drive an outbound fetch to
    // the feed-supplied URL; a short TTL blunts that while still letting a parser fix or a feed
    // that later serves a valid document recover within the hour.
    private static readonly TimeSpan NegativeCacheTtl = TimeSpan.FromMinutes(15);
    private static readonly TranscriptDocument NegativeCacheEntry = new(null, []);

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
                    // An empty segment list is the negative-cache marker (see NegativeCacheEntry).
                    return document.Segments.Count > 0 ? document : null;
                }
            }
            catch (JsonException ex)
            {
                logger.LogWarning(ex, "Discarding unreadable cached transcript for {CacheKey}", cacheKey);
            }
        }

        var result = await FetchAndParseAsync(transcriptUrl, transcriptType, cancellationToken);
        await db.StringSetAsync(
            cacheKey,
            JsonConvert.SerializeObject(result ?? NegativeCacheEntry),
            result is not null ? CacheTtl : NegativeCacheTtl);
        return result;
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
        var segments = TranscriptParsing.Parse(format, content);
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

    private static string Hash(string value)
    {
        var bytes = SHA256.HashData(Encoding.UTF8.GetBytes(value));
        return Convert.ToHexString(bytes).ToLowerInvariant();
    }
}
