using System.Net;
using System.Net.Sockets;
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
    // Overridable purely for testing — production always resolves through real DNS. Tests supply
    // canned results instead so SSRF-guard behavior (e.g. "a hostname resolving to a private
    // address is rejected") is verifiable without depending on real DNS or a live network.
    Func<string, CancellationToken, Task<IPAddress[]>>? hostResolver = null,
    // Overridable purely for testing, for the same reason as hostResolver above. Production sends
    // through the "chapters" named client (auto-redirect disabled, registered in Program.cs) rather
    // than the shared httpClient, so FetchChaptersAsync can see and re-validate every redirect hop
    // itself instead of the runtime following one transparently to an address the SSRF guard never
    // got to check. Routed through IHttpClientFactory (rather than a private static HttpClient) so
    // it still inherits the app's HTTP defaults — resilience handler, service discovery, OTel
    // instrumentation — from ConfigureHttpClientDefaults in ServiceDefaults.
    Func<Uri, CancellationToken, Task<HttpResponseMessage>>? sendChaptersRequestAsync = null,
    IHttpClientFactory? httpClientFactory = null) : IPodcastFeedClient
{
    private static readonly XNamespace ItunesNamespace = "http://www.itunes.com/dtds/podcast-1.0.dtd";
    private static readonly XNamespace PodcastNamespace = "https://podcastindex.org/namespace/1.0";
    private const int MaxChaptersRedirects = 5;

    private readonly Func<string, CancellationToken, Task<IPAddress[]>> _resolveHostAsync = hostResolver ?? Dns.GetHostAddressesAsync;
    private readonly Func<Uri, CancellationToken, Task<HttpResponseMessage>> _sendChaptersRequestAsync =
        sendChaptersRequestAsync ?? ((uri, ct) => httpClientFactory!.CreateClient("chapters")
            .GetAsync(uri, HttpCompletionOption.ResponseHeadersRead, ct));

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
        var chaptersUri = !string.IsNullOrEmpty(audioUrl) ? await ResolveFetchableChaptersUrlAsync(chaptersUrl, cancellationToken) : null;
        var chapters = chaptersUri is not null
            ? await FetchChaptersAsync(chaptersUri, cancellationToken)
            : null;

        return new Episode(id, ShowId: string.Empty, title, publishedAt, duration, audioUrl, description, bitrateKbps, fileSizeBytes, chapters);
    }

    // chaptersUrl comes straight from feed XML that a third party controls — reject anything that
    // isn't an absolute http(s) URL pointed at a public host before this server fetches it, rather
    // than relying on the request itself to fail for a bad scheme. Also resolves a hostname (rather
    // than only checking IP literals) and rejects it if ANY resolved address is
    // private/loopback/link-local — otherwise a hostname that resolves to an internal address (DNS
    // rebinding, a nip.io-style domain) would sail straight through the literal-only check.
    private async Task<Uri?> ResolveFetchableChaptersUrlAsync(string? chaptersUrl, CancellationToken cancellationToken)
    {
        if (string.IsNullOrEmpty(chaptersUrl) || !Uri.TryCreate(chaptersUrl, UriKind.Absolute, out var parsed))
        {
            return null;
        }

        if (parsed.Scheme != Uri.UriSchemeHttp && parsed.Scheme != Uri.UriSchemeHttps)
        {
            return null;
        }

        // Reject userinfo (https://user:pass@host/...) outright — GetStreamAsync would send it as
        // part of the request, and this URL comes from an untrusted feed, so a crafted one could
        // otherwise leak credentials into the warning log below on a failed fetch.
        if (!string.IsNullOrEmpty(parsed.UserInfo))
        {
            return null;
        }

        // "localhost" resolves to loopback on essentially every system without a DNS query, so
        // check it directly rather than depending on the resolver (real or test-mocked) getting
        // it right.
        if (parsed.IsLoopback || string.Equals(parsed.Host, "localhost", StringComparison.OrdinalIgnoreCase))
        {
            return null;
        }

        IPAddress[] addresses;
        if (IPAddress.TryParse(parsed.Host, out var literalAddress))
        {
            addresses = [literalAddress];
        }
        else
        {
            try
            {
                addresses = await _resolveHostAsync(parsed.Host, cancellationToken);
            }
            catch (Exception ex) when (ex is SocketException or ArgumentException)
            {
                return null;
            }
        }

        return addresses.Length > 0 && addresses.All(IsPubliclyRoutable) ? parsed : null;
    }

    // Named for what it returns true for (a fetchable public address), not what it excludes — the
    // exclusion list has grown well past just "private or loopback" (multicast, TEST-NET,
    // benchmarking, CGNAT, documentation ranges, ...) as the SSRF guard has been hardened, and a
    // name matching only the original two cases stopped reflecting what this actually checks.
    private static bool IsPubliclyRoutable(IPAddress address)
    {
        // An IPv4-mapped IPv6 address (::ffff:10.0.0.1) must be evaluated as its embedded IPv4
        // form — otherwise it skips the IPv4 range checks below entirely and only IsLoopback()
        // would ever catch it.
        if (address.IsIPv4MappedToIPv6)
        {
            address = address.MapToIPv4();
        }

        if (IPAddress.IsLoopback(address))
        {
            return false;
        }

        if (IPAddress.Any.Equals(address) || IPAddress.IPv6Any.Equals(address) || address.IsIPv6Multicast)
        {
            return false;
        }

        var bytes = address.GetAddressBytes();
        var isNonPublic = address.AddressFamily switch
        {
            AddressFamily.InterNetwork =>
                bytes[0] == 0 // "this network" (includes 0.0.0.0)
                || bytes[0] == 10
                || (bytes[0] == 172 && bytes[1] is >= 16 and <= 31)
                || (bytes[0] == 192 && bytes[1] == 168)
                || (bytes[0] == 169 && bytes[1] == 254) // link-local
                || (bytes[0] == 100 && bytes[1] is >= 64 and <= 127) // CGNAT (100.64.0.0/10)
                || (bytes[0] == 198 && bytes[1] is 18 or 19) // benchmarking (198.18.0.0/15)
                || (bytes[0] == 192 && bytes[1] == 0 && bytes[2] == 2) // TEST-NET-1 (192.0.2.0/24)
                || (bytes[0] == 198 && bytes[1] == 51 && bytes[2] == 100) // TEST-NET-2 (198.51.100.0/24)
                || (bytes[0] == 203 && bytes[1] == 0 && bytes[2] == 113) // TEST-NET-3 (203.0.113.0/24)
                || bytes[0] is >= 224 and <= 255, // multicast (224-239) + reserved Class E (240-255)
            // fc00::/7 (unique-local) covers both defined fc00::/8 and fd00::/8 blocks — checking
            // the top 7 bits directly rather than IsIPv6SiteLocal, which only recognizes the older,
            // deprecated fec0::/10 site-local range and misses unique-local entirely. The explicit
            // byte check is the IPv6 documentation range (2001:db8::/32).
            AddressFamily.InterNetworkV6 =>
                address.IsIPv6LinkLocal || address.IsIPv6SiteLocal || (bytes[0] & 0xFE) == 0xFC
                || (bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x0D && bytes[3] == 0xB8),
            _ => true, // an unrecognized address family is treated as non-routable, not public
        };

        return !isNonPublic;
    }

    // podcast:chapters points at an externally-hosted JSON document — fetched best-effort so a
    // slow or broken chapters URL can't fail the whole feed parse (the episode itself is still
    // perfectly usable without chapter markers). The spec's documented shape is a wrapped
    // { "chapters": [...] } object, but some feeds serve a bare top-level array instead — both
    // are accepted here. A single malformed chapter entry (e.g. a non-numeric startTime) is
    // skipped rather than discarding every chapter in the document.
    //
    // Sent through _sendChaptersRequestAsync (auto-redirect disabled) rather than the shared
    // httpClient, and every redirect hop is re-validated through ResolveFetchableChaptersUrlAsync
    // before being followed — otherwise the already-validated initial URL could 302/307 to a
    // private/loopback/link-local target and the runtime's own auto-redirect would follow it
    // straight past the SSRF guard.
    private async Task<IReadOnlyList<EpisodeChapter>?> FetchChaptersAsync(Uri chaptersUrl, CancellationToken cancellationToken)
    {
        var currentUrl = chaptersUrl;
        try
        {
            for (var redirectCount = 0; ; redirectCount++)
            {
                using var response = await _sendChaptersRequestAsync(currentUrl, cancellationToken);

                if (IsRedirect(response.StatusCode))
                {
                    if (redirectCount >= MaxChaptersRedirects || response.Headers.Location is null)
                    {
                        logger.LogWarning("Too many redirects (or a redirect with no Location) fetching podcast:chapters from {ChaptersUrl}", chaptersUrl);
                        return null;
                    }

                    var nextUrl = response.Headers.Location.IsAbsoluteUri
                        ? response.Headers.Location
                        : new Uri(currentUrl, response.Headers.Location);
                    var validatedNextUrl = await ResolveFetchableChaptersUrlAsync(nextUrl.ToString(), cancellationToken);
                    if (validatedNextUrl is null)
                    {
                        logger.LogWarning(
                            "Redirect from podcast:chapters {ChaptersUrl} to {RedirectUrl} was rejected by the SSRF guard",
                            chaptersUrl, nextUrl);
                        return null;
                    }

                    currentUrl = validatedNextUrl;
                    continue;
                }

                response.EnsureSuccessStatusCode();
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
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            logger.LogWarning(ex, "Failed to fetch podcast:chapters from {ChaptersUrl}", chaptersUrl);
            return null;
        }
    }

    private static bool IsRedirect(HttpStatusCode statusCode) =>
        statusCode is HttpStatusCode.MovedPermanently or HttpStatusCode.Found or HttpStatusCode.SeeOther
            or HttpStatusCode.TemporaryRedirect or HttpStatusCode.PermanentRedirect;

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
