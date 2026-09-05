using Kuulla.Web.Components.Pages;
using Kuulla.Web.Services;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Moq;

namespace Kuulla.Web.Tests.Pages;

public class LandingTests : WebTestContext
{
    public LandingTests()
    {
        // Landing's header renders <LoginDisplay />, which reads IHostEnvironment.
        var environment = new Mock<IHostEnvironment>();
        environment.SetupGet(e => e.EnvironmentName).Returns(Environments.Production);
        Services.AddSingleton(environment.Object);
    }

    private void ChangelogReturns(string markdown) =>
        Services.AddSingleton(new ChangelogProvider(() => markdown, "two4suited/kuulla"));

    [Fact]
    public void RendersWhatsNewSection_FromTheChangelog()
    {
        ChangelogReturns("""
            # Changelog

            ## 2026.9.2 — 2026-09-05

            ### Web
            - Expand the marketing page

            ### Docs
            - Add a release skill
            """);

        var cut = RenderComponent<Landing>();

        Assert.Contains("What's new", cut.Markup);
        Assert.Contains("2026.9.2", cut.Markup);
        Assert.Contains("Sep 5, 2026", cut.Markup);
        Assert.Contains("Expand the marketing page", cut.Markup);
        Assert.Contains("Add a release skill", cut.Markup);
        Assert.Contains("releases/tag/v2026.9.2", cut.Markup);
    }

    [Fact]
    public void ShowsAtMostThreeReleases()
    {
        ChangelogReturns(string.Join("\n\n", Enumerable.Range(1, 5)
            .Reverse()
            .Select(i => $"## 2026.9.{i} — 2026-09-0{i}\n### Web\n- Change {i}")));

        var cut = RenderComponent<Landing>();

        Assert.Contains("2026.9.5", cut.Markup);
        Assert.Contains("2026.9.3", cut.Markup);
        Assert.DoesNotContain("2026.9.2", cut.Markup);
    }

    [Fact]
    public void OmitsWhatsNewSection_WhenThereIsNoChangelog()
    {
        ChangelogReturns("# Changelog\n\nNothing shipped yet.");

        var cut = RenderComponent<Landing>();

        Assert.DoesNotContain("What's new", cut.Markup);
        Assert.Contains("Pause here.", cut.Markup); // the rest of the page still renders
    }
}
