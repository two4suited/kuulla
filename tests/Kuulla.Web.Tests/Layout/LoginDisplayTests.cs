using Kuulla.Web.Components.Layout;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Moq;

namespace Kuulla.Web.Tests.Layout;

public class LoginDisplayTests : WebTestContext
{
    private void SetEnvironment(string environmentName)
    {
        var environment = new Mock<IHostEnvironment>();
        environment.SetupGet(e => e.EnvironmentName).Returns(environmentName);
        Services.AddSingleton(environment.Object);
    }

    [Fact]
    public void ShowsUserName_WhenAuthenticated()
    {
        SetEnvironment(Environments.Production);
        AuthContext.SetAuthorized("test-user");

        var cut = RenderComponent<LoginDisplay>();

        Assert.Contains("Hello, test-user", cut.Markup);
        Assert.Contains("Log out", cut.Markup);
    }

    [Fact]
    public void ShowsLogIn_WhenNotAuthenticated()
    {
        SetEnvironment(Environments.Production);

        var cut = RenderComponent<LoginDisplay>();

        Assert.Contains("Log in", cut.Markup);
        Assert.DoesNotContain("Sign in as test user", cut.Markup);
    }

    [Fact]
    public void ShowsLocalTestSignIn_WhenNotAuthenticatedInDevelopment()
    {
        SetEnvironment(Environments.Development);

        var cut = RenderComponent<LoginDisplay>();

        Assert.Contains("Sign in as test user", cut.Markup);
    }
}
