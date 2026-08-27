using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Xml.Linq;
using Kuulla.Api.Models;

namespace Kuulla.Api.Services;

public class PodcastFeedClient(HttpClient httpClient, ILogger<PodcastFeedClient> logger) : IPodcastFeedClient
{
    private static readonly XNamespace ItunesNamespace = "http://www.itunes.com/dtds/podcast-1.0.dtd";
    private static readonly XNamespace PodcastNamespace = "https://podcastindex.org/namespace/1.0";

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

        var items = channel.Elements("item").ToList();
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

        var chaptersUrl = item.Element(PodcastNamespace + "chapters")?.Attribute("url")?.Value;
        var chapters = !string.IsNullOrEmpty(chaptersUrl)
            ? await FetchChaptersAsync(chaptersUrl, cancellationToken)
            : null;

        return new Episode(id, ShowId: string.Empty, title, publishedAt, duration, audioUrl, description, bitrateKbps, fileSizeBytes, chapters);
    }

    // podcast:chapters points at an externally-hosted JSON document — fetched best-effort so a
    // slow or broken chapters URL can't fail the whole feed parse (the episode itself is still
    // perfectly usable without chapter markers). The spec's documented shape is a wrapped
    // { "chapters": [...] } object, but some feeds serve a bare top-level array instead — both
    // are accepted here. A single malformed chapter entry (e.g. a non-numeric startTime) is
    // skipped rather than discarding every chapter in the document.
    private async Task<IReadOnlyList<EpisodeChapter>?> FetchChaptersAsync(string chaptersUrl, CancellationToken cancellationToken)
    {
        try
        {
            using var stream = await httpClient.GetStreamAsync(chaptersUrl, cancellationToken);
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
            logger.LogWarning(ex, "Failed to fetch podcast:chapters from {ChaptersUrl}", chaptersUrl);
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
            || startTimeSeconds < TimeSpan.MinValue.TotalSeconds
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
