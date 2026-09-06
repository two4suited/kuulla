using Kuulla.Web.Services;

namespace Kuulla.Web.Tests.Services;

public class ChangelogProviderTests
{
    private const string ThreeReleases = """
        # Changelog

        ## 2026.9.3 — 2026-09-06
        ### Web
        - Third

        ## 2026.9.2 — 2026-09-05
        ### Web
        - Second

        ## 2026.9.1 — 2026-09-04
        ### Web
        - First
        """;

    [Fact]
    public void GetRecent_returns_the_newest_entries_capped_at_count()
    {
        var provider = new ChangelogProvider(() => ThreeReleases, "o/r");

        var recent = provider.GetRecent(count: 2);

        Assert.Equal(["2026.9.3", "2026.9.2"], recent.Select(r => r.Version));
    }

    [Fact]
    public void GetRecent_returns_everything_when_fewer_than_count()
    {
        var provider = new ChangelogProvider(() => ThreeReleases, "o/r");

        Assert.Equal(3, provider.GetRecent(count: 10).Count);
    }

    [Fact]
    public void GetRecent_is_empty_when_the_changelog_is_missing()
    {
        var provider = new ChangelogProvider(() => null, "o/r");

        Assert.Empty(provider.GetRecent());
    }

    [Fact]
    public void GetRecent_reads_the_changelog_only_once()
    {
        var reads = 0;
        var provider = new ChangelogProvider(
            () => { reads++; return ThreeReleases; },
            "o/r");

        provider.GetRecent();
        provider.GetRecent();

        Assert.Equal(1, reads);
    }

    [Fact]
    public void GetRecent_merges_summaries_from_the_summaries_json_by_version()
    {
        var provider = new ChangelogProvider(
            () => ThreeReleases,
            "o/r",
            () => """{ "2026.9.3": "Newest blurb.", "2026.9.1": "Oldest blurb." }""");

        var recent = provider.GetRecent(count: 3);

        Assert.Equal("Newest blurb.", recent[0].Summary);
        Assert.Null(recent[1].Summary);
        Assert.Equal("Oldest blurb.", recent[2].Summary);
    }

    [Fact]
    public void GetRecent_ignores_an_unparseable_summaries_json()
    {
        var provider = new ChangelogProvider(() => ThreeReleases, "o/r", () => "not json");

        Assert.All(provider.GetRecent(), r => Assert.Null(r.Summary));
    }
}
