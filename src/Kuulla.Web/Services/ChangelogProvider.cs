using System.Text.Json;
using Kuulla.Web.Models;

namespace Kuulla.Web.Services;

/// <summary>
/// Supplies the marketing page's "What's new" section from the committed <c>CHANGELOG.md</c>,
/// which ships alongside the app (copied to the build output — see <c>Kuulla.Web.csproj</c>) and
/// is regenerated from the GitHub Releases by <c>.github/workflows/release.yml</c>. A sibling
/// <c>release-summaries.json</c> (written by <c>scripts/summarize-releases.sh</c>) maps each
/// version to a short plain-language blurb, shown as the entry's lead line. Both files are baked
/// at build time and never change while the process runs, so they are read and parsed once. A
/// missing or unparseable changelog yields an empty list and the section simply isn't rendered;
/// a missing summaries file just means no blurbs.
/// </summary>
public sealed class ChangelogProvider
{
    private readonly Lazy<IReadOnlyList<ReleaseNote>> releases;

    public ChangelogProvider(IConfiguration configuration, ILogger<ChangelogProvider> logger)
        : this(
            () => ReadDataFile("CHANGELOG.md", logger),
            configuration["ReleaseNotes:Repository"] is { Length: > 0 } repo ? repo : "two4suited/kuulla",
            () => ReadDataFile("release-summaries.json", logger))
    {
    }

    internal ChangelogProvider(Func<string?> readChangelog, string repository, Func<string?>? readSummaries = null)
    {
        releases = new Lazy<IReadOnlyList<ReleaseNote>>(
            () => ChangelogParser.Parse(readChangelog(), repository, ParseSummaries(readSummaries?.Invoke())));
    }

    /// <summary>The most recent releases, newest first (the changelog is authored newest-first).</summary>
    public IReadOnlyList<ReleaseNote> GetRecent(int count = 3)
    {
        var all = releases.Value;
        return count < all.Count ? all.Take(count).ToArray() : all;
    }

    private static IReadOnlyDictionary<string, string>? ParseSummaries(string? json)
    {
        if (string.IsNullOrWhiteSpace(json))
        {
            return null;
        }

        try
        {
            return JsonSerializer.Deserialize<Dictionary<string, string>>(json);
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private static string? ReadDataFile(string name, ILogger logger)
    {
        var path = Path.Combine(AppContext.BaseDirectory, name);
        try
        {
            return File.Exists(path) ? File.ReadAllText(path) : null;
        }
        catch (IOException ex)
        {
            logger.LogWarning(ex, "Could not read {Path}", path);
            return null;
        }
    }
}
