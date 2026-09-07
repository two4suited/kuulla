using System.Text;
using System.Xml;
using System.Xml.Linq;
using Kuulla.Core.Services;

namespace Kuulla.Api.Services;

public interface IOpmlExportService
{
    // The caller's subscriptions as a valid OPML 2.0 document. Round-trips with OpmlParser: every
    // <outline> it emits parses straight back to the feed URL it was built from.
    Task<string> ExportAsync(string userId, CancellationToken cancellationToken);
}

public class OpmlExportService(ISubscriptionService subscriptionService, IShowService showService)
    : IOpmlExportService
{
    public async Task<string> ExportAsync(string userId, CancellationToken cancellationToken)
    {
        var subscriptions = await subscriptionService.GetSubscriptionsAsync(userId, cancellationToken);

        var entries = await Task.WhenAll(subscriptions.Select(async subscription => new
        {
            subscription.ShowTitle,
            // Snapshotted on subscribe (#421); only rows that predate that field cost a show read.
            FeedUrl = subscription.FeedUrl
                ?? await showService.TryGetFeedUrlAsync(subscription.ShowId, cancellationToken),
        }));

        var body = new XElement("body");
        foreach (var entry in entries
            .Where(e => !string.IsNullOrEmpty(e.FeedUrl))
            // Stable ordering so re-exports diff cleanly; feed URL breaks title ties.
            .OrderBy(e => e.ShowTitle, StringComparer.OrdinalIgnoreCase)
            .ThenBy(e => e.FeedUrl, StringComparer.Ordinal))
        {
            body.Add(new XElement("outline",
                new XAttribute("type", "rss"),
                new XAttribute("text", entry.ShowTitle),
                new XAttribute("title", entry.ShowTitle),
                new XAttribute("xmlUrl", entry.FeedUrl!)));
        }

        var document = new XDocument(
            new XDeclaration("1.0", "utf-8", null),
            new XElement("opml",
                new XAttribute("version", "2.0"),
                new XElement("head",
                    new XElement("title", "Kuulla subscriptions"),
                    new XElement("dateCreated", DateTimeOffset.UtcNow.ToString("r"))),
                body));

        using var writer = new Utf8StringWriter();
        using (var xml = XmlWriter.Create(writer, new XmlWriterSettings { Indent = true }))
        {
            document.Save(xml);
        }

        return writer.ToString();
    }

    // XmlWriter takes the declaration's encoding from the TextWriter's own Encoding, and a plain
    // StringWriter reports UTF-16 — so without this the document would announce encoding="utf-16"
    // while the endpoint serves it as UTF-8 bytes.
    private sealed class Utf8StringWriter : StringWriter
    {
        public override Encoding Encoding => Encoding.UTF8;
    }
}
