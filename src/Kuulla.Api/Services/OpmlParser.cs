using System.Text;
using System.Xml;
using System.Xml.Linq;
using Kuulla.Core.Services;

namespace Kuulla.Api.Services;

// One feed pulled out of an OPML subscription list.
public record OpmlFeed(string Title, string FeedUrl);

// Parses an OPML subscription list — the interchange format every podcast app imports and
// exports — into a flat list of feeds. OPML is loosely specified and the files real apps produce
// vary wildly, so this is deliberately lenient about any single entry and strict only about
// whole-document validity and size.
public static class OpmlParser
{
    // A hand-maintained OPML from a podcast app is a few KB; 5 MB is already many thousands of
    // feeds. Past this we assume the upload is hostile or malformed and refuse to parse it.
    public const int MaxDocumentBytes = 5 * 1024 * 1024;

    // Power users on other apps top out in the low hundreds of subscriptions. 5000 is far past
    // any real library and bounds the fan-out the importer (#421) does across these entries.
    public const int MaxFeeds = 5000;

    // Real OPML nests folders one or two deep. This only exists so a pathologically deep document
    // (which the byte cap alone would still let recurse thousands of frames) can't overflow the
    // stack — an uncatchable crash — before the feed cap or size cap trips.
    private const int MaxDepth = 64;

    // Thrown for anything wrong with the document as a whole (not well-formed, no <body>, over a
    // limit). The import endpoint maps this to a 400. A single malformed <outline> is skipped
    // rather than raised.
    public static IReadOnlyList<OpmlFeed> Parse(string opml)
    {
        ArgumentNullException.ThrowIfNull(opml);

        if (Encoding.UTF8.GetByteCount(opml) > MaxDocumentBytes)
        {
            throw new FormatException($"OPML document exceeds the {MaxDocumentBytes / (1024 * 1024)} MB limit.");
        }

        // Parse an untrusted upload with DTDs prohibited outright and no external resolver, so a
        // hostile DOCTYPE — entity-expansion ("billion laughs"), external-entity SSRF/file reads —
        // is a well-formed-XML rejection here rather than something the parser acts on.
        var settings = new XmlReaderSettings
        {
            DtdProcessing = DtdProcessing.Prohibit,
            XmlResolver = null,
        };

        XDocument document;
        try
        {
            using var reader = XmlReader.Create(new StringReader(opml), settings);
            document = XDocument.Load(reader);
        }
        catch (XmlException ex)
        {
            throw new FormatException("OPML document is not well-formed XML.", ex);
        }

        var body = document.Root?.Element("body");
        if (body is null)
        {
            throw new FormatException("OPML document has no <body> element.");
        }

        var feeds = new List<OpmlFeed>();
        var seen = new HashSet<string>();
        Collect(body, feeds, seen, depth: 0);
        return feeds;
    }

    private static void Collect(XElement parent, List<OpmlFeed> feeds, HashSet<string> seen, int depth)
    {
        if (depth > MaxDepth)
        {
            throw new FormatException($"OPML document nests outlines more than {MaxDepth} levels deep.");
        }

        foreach (var outline in parent.Elements("outline"))
        {
            var xmlUrl = outline.Attribute("xmlUrl")?.Value;

            // A folder outline has no xmlUrl; an outline typed as something other than a feed
            // (type="link", "note", …) isn't one either. Either way it's skipped, not fatal.
            if (!string.IsNullOrWhiteSpace(xmlUrl) && IsFeedType(outline.Attribute("type")?.Value))
            {
                // Normalize now so dedup here and the importer's "already subscribed?" check
                // (#421) key off the exact same string.
                var normalized = FeedUrl.Normalize(xmlUrl.Trim());
                if (seen.Add(normalized))
                {
                    if (feeds.Count >= MaxFeeds)
                    {
                        throw new FormatException($"OPML document has more than {MaxFeeds} feeds.");
                    }

                    var title = FirstNonEmpty(
                        outline.Attribute("title")?.Value,
                        outline.Attribute("text")?.Value) ?? normalized;
                    feeds.Add(new OpmlFeed(title, normalized));
                }
            }

            // Folders nest <outline> within <outline>; recurse regardless of whether this one was
            // itself a feed so a feed filed under a category still gets collected.
            Collect(outline, feeds, seen, depth + 1);
        }
    }

    // No type attribute is the common case (many exporters omit it); "rss" is the OPML podcast
    // convention and "atom" shows up too.
    private static bool IsFeedType(string? type) =>
        string.IsNullOrWhiteSpace(type)
        || type.Equals("rss", StringComparison.OrdinalIgnoreCase)
        || type.Equals("atom", StringComparison.OrdinalIgnoreCase);

    private static string? FirstNonEmpty(params string?[] values) =>
        values.FirstOrDefault(v => !string.IsNullOrWhiteSpace(v))?.Trim();
}
