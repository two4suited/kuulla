using Bunit;
using Bunit.TestDoubles;
using Kuulla.Web.Services;
using Microsoft.Extensions.DependencyInjection;
using Moq;

namespace Kuulla.Web.Tests;

public abstract class WebTestContext : TestContext
{
    protected TestAuthorizationContext AuthContext { get; }

    protected WebTestContext()
    {
        AuthContext = this.AddTestAuthorization();

        Services.AddScoped<KuullaApiClient>();
        Services.AddScoped<PodcastCatalogClient>();
        Services.AddScoped<SubscriptionClient>();
        Services.AddScoped<SettingsClient>();
        Services.AddScoped<EpisodeStateClient>();
        Services.AddScoped<PlaylistClient>();

        // The marketing landing page (also shown by Home's NotAuthorized branch) reads release
        // notes through ChangelogProvider. Default to an empty changelog so the "What's new"
        // section stays out of the markup under test; LandingTests overrides this with content.
        Services.AddSingleton(new ChangelogProvider(() => null, "owner/repo"));
    }

    protected void ConfigureApi(HttpMessageHandler handler)
    {
        var httpClient = new HttpClient(handler) { BaseAddress = new Uri("http://localhost/") };
        var factory = new Mock<IHttpClientFactory>();
        factory.Setup(f => f.CreateClient("api")).Returns(httpClient);
        Services.AddSingleton(factory.Object);
    }
}
