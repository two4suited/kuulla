namespace Kuulla.Core.Services;

// An OPML entry identifies a podcast only by its feed URL, so the feed URL is the identity key
// for the whole import path: the dedup check that skips feeds a user already has, and the
// deterministic Show.Id derived in ShowService.GetOrCreateByFeedUrlAsync. Small textual
// differences that point at the same feed — a capitalised host, an explicit :443, a trailing
// slash, http vs https — have to collapse to one key or the same show imports twice.
public static class FeedUrl
{
    // Fold http onto https rather than probing which scheme the host actually serves: this is a
    // pure, offline key and virtually every podcast host serves both (or 301s http to https).
    // Two genuinely distinct feeds that differ only by scheme are vanishingly rare and not worth
    // a network round-trip per OPML entry to tell apart.
    public static string Normalize(string feedUrl)
    {
        ArgumentNullException.ThrowIfNull(feedUrl);
        var trimmed = feedUrl.Trim();

        if (!Uri.TryCreate(trimmed, UriKind.Absolute, out var uri)
            || (uri.Scheme != Uri.UriSchemeHttp && uri.Scheme != Uri.UriSchemeHttps))
        {
            // Nothing we can meaningfully canonicalise — hand it back trimmed so callers still
            // have a stable key, and let the downstream feed fetch be what ultimately fails.
            return trimmed;
        }

        var host = uri.Host.ToLowerInvariant();

        // Drop the port when it's the scheme default (80/443, in either direction so a stray
        // http://host:443 still collapses); keep a genuinely non-standard port like :8080.
        var port = uri.IsDefaultPort || uri.Port is 80 or 443 ? string.Empty : $":{uri.Port}";

        // Trailing slashes are cosmetic ("/feed/" == "/feed"); a bare root path drops entirely.
        var path = uri.AbsolutePath.TrimEnd('/');

        // Query is preserved — some feeds genuinely select content with it ("?format=rss").
        return $"https://{host}{port}{path}{uri.Query}";
    }
}
