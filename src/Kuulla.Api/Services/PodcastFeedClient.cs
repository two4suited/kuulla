using System.Security.Cryptography;
using System.Text;
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

        var description = FirstNonEmpty(
            channel.Element(ItunesNamespace + "summary")?.Value,
            channel.Element("description")?.Value);

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
        var publishedAt = DateTimeOffset.TryParse(item.Element("pubDate")?.Value, out var pubDate)
            ? pubDate
            : (DateTimeOffset?)null;
        var duration = ParseDuration(item.Element(ItunesNamespace + "duration")?.Value);
        var bitrateKbps = fileSizeBytes is not null && duration is { TotalSeconds: > 0 }
            ? (int)(fileSizeBytes.Value * 8 / 1000 / duration.Value.TotalSeconds)
            : (int?)null;

        var guid = item.Element("guid")?.Value;
        var id = !string.IsNullOrEmpty(guid) ? Hash(guid) : Hash(audioUrl);

        return new Episode(id, ShowId: string.Empty, title, publishedAt, duration, audioUrl, bitrateKbps, fileSizeBytes);
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
        try
        {
            switch (parts.Length)
            {
                case 3:
                    hours = int.Parse(parts[0]);
                    minutes = int.Parse(parts[1]);
                    seconds = int.Parse(parts[2]);
                    break;
                case 2:
                    minutes = int.Parse(parts[0]);
                    seconds = int.Parse(parts[1]);
                    break;
                default:
                    return null;
            }
        }
        catch (FormatException)
        {
            return null;
        }

        return new TimeSpan(hours, minutes, seconds);
    }

    private static string? FirstNonEmpty(params string?[] values) =>
        values.FirstOrDefault(v => !string.IsNullOrWhiteSpace(v))?.Trim();

    private static string Hash(string value)
    {
        var bytes = SHA256.HashData(Encoding.UTF8.GetBytes(value));
        return Convert.ToHexString(bytes)[..32].ToLowerInvariant();
    }
}
