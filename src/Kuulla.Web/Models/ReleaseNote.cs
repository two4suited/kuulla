namespace Kuulla.Web.Models;

/// <summary>
/// One released version, as parsed from the committed <c>CHANGELOG.md</c> (which the release
/// workflow regenerates from the GitHub Releases). Rendered in the marketing page's "What's new"
/// section: the CalVer version, the day it shipped, an optional plain-language <see cref="Summary"/>,
/// the label-grouped change list, and a link to the GitHub Release.
/// </summary>
/// <param name="Summary">
/// A short "what's new" blurb from <c>release-summaries.json</c> (written by
/// <c>scripts/summarize-releases.sh</c>), shown as the entry's lead line with the raw
/// <see cref="Groups"/> moved into a "Full notes" expander. <c>null</c> when no blurb exists yet.
/// </param>
public record ReleaseNote(
    string Version,
    DateOnly? PublishedOn,
    IReadOnlyList<ReleaseNoteGroup> Groups,
    string Url,
    string? Summary = null);

/// <summary>One <c>### Heading</c> section of a changelog entry and its bullet items.</summary>
public record ReleaseNoteGroup(string Title, IReadOnlyList<string> Items);
