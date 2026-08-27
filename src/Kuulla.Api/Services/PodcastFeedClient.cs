using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Xml.Linq;
using Kuulla.Api.Models;

namespace Kuulla.Api.Services;

public class PodcastFeedClient(
    HttpClient httpClient,
    ILogger<PodcastFeedClient> logger,
    // Fetches the externally-hosted podcast:chapters JSON with the shared SSRF guard (public-host
    // validation + per-redirect-hop re-validation). See PublicResourceFetcher.
    PublicResourceFetcher resourceFetcher) : IPodcastFeedClient
{
    private static readonly XNamespace ItunesNamespace = "http://www.itunes.com/dtds/podcast-1.0.dtd";
    private static readonly XNamespace PodcastNamespace = "https://podcastindex.org/namespace/1.0";

    // podcast:transcript type attributes vary by feed. Rank so a machine-friendly JSON transcript
    // wins over SRT/VTT, and a plain-text or HTML transcript (which the endpoint can't turn into
    // timed segments) is only taken as a last resort.
    private static readonly string[] TranscriptTypePreference =
        ["application/json", "text/vtt", "application/x-subrip", "application/srt", "text/html", "text/plain"];

    public async Task<PodcastFeedContent?> FetchAsync(string feedUrl, CancellationToken cancellationToken)
    {
        await using var stream = await httpClient.GetStreamAsync(feedUrl, cancellationToken);
        var document = await XDocument.LoadAsync(stream, LoadOptions.None, cancellationToken);
        var channel = document.Root?.Element("channel");
        if (channel is null)
        {
            return null;
        }

        var description = StripHtml(FirstNonEmpty(
            channel.Element(ItunesNamespace + "summary")?.Value,
            channel.Element("description")?.Value));

        // Cloned rather than referencing the shared XDocument's nodes directly — LINQ-to-XML gives
        // no thread-safety guarantee for concurrent reads across the parallel loop below, and a
        // clone gives each task its own independent tree to read from.
        var items = channel.Elements("item").Select(item => new XElement(item)).ToList();
        var parsedEpisodes = new Episode[items.Count];
        await Parallel.ForEachAsync(
            Enumerable.Range(0, items.Count),
            new ParallelOptions { MaxDegreeOfParallelism = 20, CancellationToken = cancellationToken },
            async (i, ct) => parsedEpisodes[i] = await ParseEpisodeAsync(items[i], ct));

        var episodes = parsedEpisodes
            .Where(episode => !string.IsNullOrEmpty(episode.AudioUrl))
            .ToList();

        return new PodcastFeedContent(description, episodes);
    }

    private async Task<Episode> ParseEpisodeAsync(XElement item, CancellationToken cancellationToken)
    {
        var enclosure = item.Element("enclosure");
        var audioUrl = enclosure?.Attribute("url")?.Value ?? string.Empty;
        var fileSizeBytes = long.TryParse(enclosure?.Attribute("length")?.Value, out var length) && length > 0
            ? length
            : (long?)null;

        var title = FirstNonEmpty(item.Element("title")?.Value, "Untitled episode")!;
        var description = StripHtml(FirstNonEmpty(
            item.Element(ItunesNamespace + "summary")?.Value,
            item.Element("description")?.Value));
        var publishedAt = DateTimeOffset.TryParse(item.Element("pubDate")?.Value, out var pubDate)
            ? pubDate
            : (DateTimeOffset?)null;
        var duration = ParseDuration(item.Element(ItunesNamespace + "duration")?.Value);
        var bitrateKbps = fileSizeBytes is not null && duration is { TotalSeconds: > 0 }
            ? (int)(fileSizeBytes.Value * 8 / 1000 / duration.Value.TotalSeconds)
            : (int?)null;

        var guid = item.Element("guid")?.Value;
        var id = !string.IsNullOrEmpty(guid) ? Hash(guid) : Hash(audioUrl);

        // Gated on audioUrl too — an item with no enclosure is filtered out by FetchAsync's
        // Where(AudioUrl) regardless, so fetching its chapters would just be a wasted HTTP request
        // (and a spurious warning log on failure) for something that's discarded either way.
        var chaptersUrl = item.Element(PodcastNamespace + "chapters")?.Attribute("url")?.Value;
        var chaptersUri = !string.IsNullOrEmpty(audioUrl)
            ? await resourceFetcher.ResolveFetchableUrlAsync(chaptersUrl, cancellationToken)
            : null;
        var chapters = chaptersUri is not null
            ? await FetchChaptersAsync(chaptersUri, cancellationToken)
            : null;

        // Unlike chapters, the transcript document is not fetched here — only the URL and its
        // declared type are recorded, and the transcript endpoint fetches/normalizes on demand
        // (and caches). Transcripts are large and most episode views never open one.
        var (transcriptUrl, transcriptType) = ExtractPreferredTranscript(item);

        return new Episode(
            id, ShowId: string.Empty, title, publishedAt, duration, audioUrl, description, bitrateKbps,
            fileSizeBytes, chapters, transcriptUrl, transcriptType);
    }

    // Podcasting 2.0 allows multiple <podcast:transcript> tags per item (e.g. one JSON, one SRT).
    // Pick the one whose declared type ranks best in TranscriptTypePreference; an unranked type
    // still beats no transcript at all but loses to any ranked one. A tag with no url is ignored.
    private static (string? Url, string? Type) ExtractPreferredTranscript(XElement item)
    {
        var best = default((string Url, string? Type, int Rank));
        var found = false;

        foreach (var tag in item.Elements(PodcastNamespace + "transcript"))
        {
            var url = tag.Attribute("url")?.Value;
            if (string.IsNullOrWhiteSpace(url))
            {
                continue;
            }

            // Normalize to a bare MIME type: strip any parameters ("application/json; charset=utf-8"
            // -> "application/json") and treat blank as absent, so both rank correctly and the
            // value stored on Episode.TranscriptType stays a bare type as its model comment expects.
            var rawType = tag.Attribute("type")?.Value;
            var type = string.IsNullOrWhiteSpace(rawType) ? null : rawType.Split(';', 2)[0].Trim();
            if (string.IsNullOrEmpty(type))
            {
                type = null;
            }

            var rank = type is null
                ? TranscriptTypePreference.Length
                : Array.FindIndex(TranscriptTypePreference, t => string.Equals(t, type, StringComparison.OrdinalIgnoreCase));
            if (rank < 0)
            {
                rank = TranscriptTypePreference.Length;
            }

            if (!found || rank < best.Rank)
            {
                best = (url.Trim(), type, rank);
                found = true;
            }
        }

        return found ? (best.Url, best.Type) : (null, null);
    }

    // podcast:chapters points at an externally-hosted JSON document — fetched best-effort (through
    // the shared SSRF-guarded PublicResourceFetcher) so a slow or broken chapters URL can't fail
    // the whole feed parse; the episode itself is still perfectly usable without chapter markers.
    // The spec's documented shape is a wrapped { "chapters": [...] } object, but some feeds serve
    // a bare top-level array instead — both are accepted. A single malformed chapter entry (e.g. a
    // non-numeric startTime) is skipped rather than discarding every chapter in the document.
    private async Task<IReadOnlyList<EpisodeChapter>?> FetchChaptersAsync(Uri chaptersUrl, CancellationToken cancellationToken)
    {
        using var response = await resourceFetcher.SendAsync(chaptersUrl, "podcast:chapters", cancellationToken);
        if (response is null)
        {
            return null;
        }

        try
        {
            await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken);
            using var document = await JsonDocument.ParseAsync(stream, cancellationToken: cancellationToken);
            var chaptersElement = document.RootElement.ValueKind == JsonValueKind.Array
                ? document.RootElement
                : document.RootElement.TryGetProperty("chapters", out var nested) ? nested : default;

            if (chaptersElement.ValueKind != JsonValueKind.Array)
            {
                return null;
            }

            var chapters = new List<EpisodeChapter>();
            foreach (var chapterElement in chaptersElement.EnumerateArray())
            {
                if (TryParseChapter(chapterElement, out var chapter))
                {
                    chapters.Add(chapter);
                }
            }

            return chapters;
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            logger.LogWarning(ex, "Failed to parse podcast:chapters from {ChaptersUrl}", chaptersUrl);
            return null;
        }
    }

    private static bool TryParseChapter(JsonElement element, out EpisodeChapter chapter)
    {
        chapter = null!;
        // Finite-and-in-range check before TimeSpan.FromSeconds, rather than a try/catch around
        // it — an out-of-range or non-finite value (NaN, an absurdly large number) would otherwise
        // throw ArgumentException/OverflowException, and since that propagates out of this method
        // it's the caller's foreach loop — not just this one entry — that would stop.
        if (!element.TryGetProperty("startTime", out var startTimeElement)
            || !startTimeElement.TryGetDouble(out var startTimeSeconds)
            || !double.IsFinite(startTimeSeconds)
            || startTimeSeconds < 0
            || startTimeSeconds > TimeSpan.MaxValue.TotalSeconds)
        {
            return false;
        }

        var title = element.TryGetProperty("title", out var titleElement) && titleElement.ValueKind == JsonValueKind.String
            ? titleElement.GetString()
            : null;
        var img = element.TryGetProperty("img", out var imgElement) && imgElement.ValueKind == JsonValueKind.String
            ? imgElement.GetString()
            : null;
        var url = element.TryGetProperty("url", out var urlElement) && urlElement.ValueKind == JsonValueKind.String
            ? urlElement.GetString()
            : null;

        chapter = new EpisodeChapter(TimeSpan.FromSeconds(startTimeSeconds), title ?? string.Empty, img, url);
        return true;
    }

    // itunes:duration is either plain seconds ("1800") or "HH:MM:SS" / "MM:SS".
    private static TimeSpan? ParseDuration(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw))
        {
            return null;
        }

        if (int.TryParse(raw, out var totalSeconds))
        {
            return TimeSpan.FromSeconds(totalSeconds);
        }

        var parts = raw.Split(':');
        int hours = 0, minutes, seconds;
        switch (parts.Length)
        {
            case 3:
                if (!int.TryParse(parts[0], out hours) || !int.TryParse(parts[1], out minutes) || !int.TryParse(parts[2], out seconds))
                {
                    return null;
                }
                break;
            case 2:
                if (!int.TryParse(parts[0], out minutes) || !int.TryParse(parts[1], out seconds))
                {
                    return null;
                }
                break;
            default:
                return null;
        }

        try
        {
            return new TimeSpan(hours, minutes, seconds);
        }
        catch (ArgumentOutOfRangeException)
        {
            return null;
        }
    }

    private static string? FirstNonEmpty(params string?[] values) =>
        values.FirstOrDefault(v => !string.IsNullOrWhiteSpace(v))?.Trim();

    private static readonly Regex HtmlBlockBreakRegex = new(
        "</p>|</div>|<br\\s*/?>", RegexOptions.Compiled | RegexOptions.IgnoreCase);
    private static readonly Regex HtmlTagRegex = new("<[^>]+>", RegexOptions.Compiled);
    private static readonly Regex BlankLineRegex = new(@"\n[ \t]*\n(\s*\n)*", RegexOptions.Compiled);

    // RSS description/summary fields are frequently HTML (podcast feeds commonly wrap show
    // notes in <p>/<a> tags), but the UI renders these as plain text — Blazor HTML-encodes
    // interpolated values, so unstripped markup would show up as literal "<p>...</p>" rather
    // than being interpreted. Turn block-level breaks into newlines before stripping the
    // remaining tags, so paragraph structure survives for the "white-space: pre-wrap" display.
    private static string? StripHtml(string? value)
    {
        if (string.IsNullOrEmpty(value))
        {
            return value;
        }

        var withBreaks = HtmlBlockBreakRegex.Replace(value, "\n");
        var withoutTags = HtmlTagRegex.Replace(withBreaks, string.Empty);
        var decoded = WebUtility.HtmlDecode(withoutTags);
        var collapsedBlankLines = BlankLineRegex.Replace(decoded, "\n\n");
        return string.Join('\n', collapsedBlankLines
            .Split('\n')
            .Select(line => line.Trim())).Trim();
    }

    private static string Hash(string value)
    {
        var bytes = SHA256.HashData(Encoding.UTF8.GetBytes(value));
        return Convert.ToHexString(bytes)[..32].ToLowerInvariant();
    }
}
