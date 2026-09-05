namespace Kuulla.Web.Models;

/// <summary>
/// One released version, as parsed from the committed <c>CHANGELOG.md</c> (which the release
/// workflow regenerates from the GitHub Releases). Rendered in the marketing page's "What's new"
/// section: the CalVer version, the day it shipped, the label-grouped change list, and a link to
/// the GitHub Release.
/// </summary>
public record ReleaseNote(
    string Version,
    DateOnly? PublishedOn,
    IReadOnlyList<ReleaseNoteGroup> Groups,
    string Url);

/// <summary>One <c>### Heading</c> section of a changelog entry and its bullet items.</summary>
public record ReleaseNoteGroup(string Title, IReadOnlyList<string> Items);
