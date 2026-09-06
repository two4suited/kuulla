using Kuulla.Web.Components.Pages;
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

    [Fact]
    public void RendersTheMarketingContent()
    {
        var cut = RenderComponent<Landing>();

        Assert.Contains("Pause here.", cut.Markup);
        Assert.Contains("A full player, not a demo", cut.Markup);
        Assert.Contains("Open web player", cut.Markup);
    }
}
