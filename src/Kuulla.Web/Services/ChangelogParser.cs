using System.Globalization;
using Kuulla.Web.Models;

namespace Kuulla.Web.Services;

/// <summary>
/// Parses the committed <c>CHANGELOG.md</c> — the format
/// <c>.github/workflows/release.yml</c> regenerates from the GitHub Releases:
/// <code>
/// ## 2026.9.2 — 2026-09-05
/// ### Web
/// - Expand the marketing page
/// </code>
/// The <c># Changelog</c> title, HTML comments, and blank lines are ignored; a <c>##</c> with no
/// change bullets under it is dropped.
/// </summary>
internal static class ChangelogParser
{
    // "## <version> — <yyyy-MM-dd>"; the date (and its dash) are optional.
    private static readonly char[] DateSeparators = ['—', '–']; // em dash, en dash

    public static IReadOnlyList<ReleaseNote> Parse(string? markdown, string repository)
    {
        if (string.IsNullOrWhiteSpace(markdown))
        {
            return [];
        }

        var releases = new List<ReleaseNote>();

        string? version = null;
        DateOnly? publishedOn = null;
        var groups = new List<ReleaseNoteGroup>();
        string? groupTitle = null;
        var groupItems = new List<string>();

        void FlushGroup()
        {
            if (groupTitle is not null && groupItems.Count > 0)
            {
                groups.Add(new ReleaseNoteGroup(groupTitle, groupItems.ToArray()));
            }

            groupItems = [];
        }

        void FlushRelease()
        {
            FlushGroup();
            if (version is not null && groups.Count > 0)
            {
                releases.Add(new ReleaseNote(
                    version,
                    publishedOn,
                    groups.ToArray(),
                    $"https://github.com/{repository}/releases/tag/v{version}"));
            }

            groups = [];
            groupTitle = null;
        }

        foreach (var raw in markdown.Split('\n'))
        {
            var line = raw.Trim();

            if (line.StartsWith("## ", StringComparison.Ordinal))
            {
                FlushRelease();
                (version, publishedOn) = ParseHeading(line[3..]);
            }
            else if (line.StartsWith("### ", StringComparison.Ordinal))
            {
                FlushGroup();
                groupTitle = line[4..].Trim();
            }
            else if (line.StartsWith("- ", StringComparison.Ordinal) || line.StartsWith("* ", StringComparison.Ordinal))
            {
                var item = line[2..].Trim();
                if (item.Length > 0 && groupTitle is not null)
                {
                    groupItems.Add(item);
                }
            }
        }

        FlushRelease();
        return releases;
    }

    private static (string Version, DateOnly? PublishedOn) ParseHeading(string heading)
    {
        var separator = heading.IndexOfAny(DateSeparators);
        if (separator < 0)
        {
            return (heading.Trim(), null);
        }

        var version = heading[..separator].Trim();
        var rest = heading[(separator + 1)..].Trim();
        return DateOnly.TryParseExact(rest, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var date)
            ? (version, date)
            : (version, null);
    }
}
