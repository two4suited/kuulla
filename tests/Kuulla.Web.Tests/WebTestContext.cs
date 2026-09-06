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
    }

    protected void ConfigureApi(HttpMessageHandler handler)
    {
        var httpClient = new HttpClient(handler) { BaseAddress = new Uri("http://localhost/") };
        var factory = new Mock<IHttpClientFactory>();
        factory.Setup(f => f.CreateClient("api")).Returns(httpClient);
        Services.AddSingleton(factory.Object);
    }
}
