using Kuulla.Web.Models;

namespace Kuulla.Web.Services;

/// <summary>
/// Supplies the marketing page's "What's new" section from the committed <c>CHANGELOG.md</c>,
/// which ships alongside the app (copied to the build output — see <c>Kuulla.Web.csproj</c>) and
/// is regenerated from the GitHub Releases by <c>.github/workflows/release.yml</c>. The file is
/// baked at build time and never changes while the process runs, so it is read and parsed once.
/// A missing or unparseable file yields an empty list and the section simply isn't rendered.
/// </summary>
public sealed class ChangelogProvider
{
    private readonly Lazy<IReadOnlyList<ReleaseNote>> releases;

    public ChangelogProvider(IConfiguration configuration, ILogger<ChangelogProvider> logger)
        : this(
            () => ReadChangelogFile(logger),
            configuration["ReleaseNotes:Repository"] is { Length: > 0 } repo ? repo : "two4suited/kuulla")
    {
    }

    internal ChangelogProvider(Func<string?> readChangelog, string repository)
    {
        releases = new Lazy<IReadOnlyList<ReleaseNote>>(() => ChangelogParser.Parse(readChangelog(), repository));
    }

    /// <summary>The most recent releases, newest first (the changelog is authored newest-first).</summary>
    public IReadOnlyList<ReleaseNote> GetRecent(int count = 3)
    {
        var all = releases.Value;
        return count < all.Count ? all.Take(count).ToArray() : all;
    }

    private static string? ReadChangelogFile(ILogger logger)
    {
        var path = Path.Combine(AppContext.BaseDirectory, "CHANGELOG.md");
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
