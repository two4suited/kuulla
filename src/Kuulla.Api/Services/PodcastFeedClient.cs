using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Xml.Linq;
using Kuulla.Api.Models;

namespace Kuulla.Api.Services;

public class PodcastFeedClient(HttpClient httpClient) : IPodcastFeedClient
{
    private static readonly XNamespace ItunesNamespace = "http://www.itunes.com/dtds/podcast-1.0.dtd";

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

        var episodes = channel.Elements("item")
            .Select(ParseEpisode)
            .Where(episode => !string.IsNullOrEmpty(episode.AudioUrl))
            .ToList();

        return new PodcastFeedContent(description, episodes);
    }

    private static Episode ParseEpisode(XElement item)
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

        return new Episode(id, ShowId: string.Empty, title, publishedAt, duration, audioUrl, description, bitrateKbps, fileSizeBytes);
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
