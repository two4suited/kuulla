using Kuulla.Web.Services;

namespace Kuulla.Web.Tests.Services;

public class ChangelogParserTests
{
    // The shape scripts/generate-changelog.sh produces.
    private const string Sample = """
        # Changelog

        <!-- Generated from the GitHub Releases by scripts/generate-changelog.sh. Do not edit by hand. -->

        ## 2026.9.2 — 2026-09-05

        ### Web
        - Expand the marketing page with a feature grid and a second shot

        ### Docs
        - Add a "release" skill wrapping the release runbook

        ## 2026.9.1 — 2026-09-04

        ### Other
        - Build dynamic playlists from unplayed episodes only
        """;

    [Fact]
    public void Parse_reads_versions_newest_first_with_dates()
    {
        var releases = ChangelogParser.Parse(Sample, "two4suited/kuulla");

        Assert.Equal(["2026.9.2", "2026.9.1"], releases.Select(r => r.Version));
        Assert.Equal(new DateOnly(2026, 9, 5), releases[0].PublishedOn);
        Assert.Equal(new DateOnly(2026, 9, 4), releases[1].PublishedOn);
    }

    [Fact]
    public void Parse_groups_items_under_their_headings()
    {
        var release = ChangelogParser.Parse(Sample, "two4suited/kuulla")[0];

        Assert.Equal(["Web", "Docs"], release.Groups.Select(g => g.Title));
        Assert.Equal("Expand the marketing page with a feature grid and a second shot", release.Groups[0].Items.Single());
    }

    [Fact]
    public void Parse_builds_the_release_tag_url_from_the_repository()
    {
        var release = ChangelogParser.Parse(Sample, "two4suited/kuulla")[0];

        Assert.Equal("https://github.com/two4suited/kuulla/releases/tag/v2026.9.2", release.Url);
    }

    [Fact]
    public void Parse_tolerates_a_heading_with_no_date()
    {
        var release = Assert.Single(ChangelogParser.Parse("## 2026.9.0\n### Other\n- Something", "o/r"));

        Assert.Equal("2026.9.0", release.Version);
        Assert.Null(release.PublishedOn);
    }

    [Fact]
    public void Parse_drops_a_version_with_no_change_bullets()
    {
        var releases = ChangelogParser.Parse("## 2026.9.3 — 2026-09-06\n\n## 2026.9.2 — 2026-09-05\n### Other\n- Real change", "o/r");

        Assert.Equal(["2026.9.2"], releases.Select(r => r.Version));
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("# Changelog\n\nNothing shipped yet.")]
    public void Parse_returns_empty_when_there_is_nothing_to_show(string? markdown)
    {
        Assert.Empty(ChangelogParser.Parse(markdown, "o/r"));
    }

    [Fact]
    public void Parse_attaches_a_summary_by_version_when_one_is_supplied()
    {
        var summaries = new Dictionary<string, string> { ["2026.9.2"] = "The marketing page grew." };

        var releases = ChangelogParser.Parse(Sample, "two4suited/kuulla", summaries);

        Assert.Equal("The marketing page grew.", releases[0].Summary);
        Assert.Null(releases[1].Summary); // no entry for 2026.9.1
    }

    [Fact]
    public void Parse_leaves_summary_null_when_no_map_is_supplied()
    {
        Assert.All(ChangelogParser.Parse(Sample, "o/r"), r => Assert.Null(r.Summary));
    }
}
