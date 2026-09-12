using System.Net.Sockets;
using Kuulla.Core.Services;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;

namespace Kuulla.Core;

// Single wiring point for the domain services that used to be registered inline in the API's
// Program.cs. Both hosts that run this logic — the API (until the feed-poll cutover, #38) and the
// Kuulla.FeedPoller worker — call this so they get identical registrations. Cosmos containers and
// the notification stack (APNs vs. no-op) stay a host concern: each host still calls
// AddKeyedAzureCosmosContainer(...) and picks an INotificationService itself.
public static class CoreServiceCollectionExtensions
{
    public static IServiceCollection AddKuullaCore(this IServiceCollection services, IConfiguration configuration)
    {
        services.Configure<FeedPollingOptions>(configuration.GetSection("FeedPolling"));

        services.AddScoped<IShowService, ShowService>();
        services.AddScoped<IEpisodeService, EpisodeService>();
        services.AddScoped<ISubscriptionService, SubscriptionService>();
        services.AddScoped<ISettingsService, SettingsService>();
        services.AddScoped<IEpisodeStateService, EpisodeStateService>();
        services.AddScoped<IDeviceTokenService, DeviceTokenService>();
        services.AddScoped<IFeedPollingService, FeedPollingService>();

        services.AddHttpClient<IPodcastDirectoryClient, ItunesPodcastDirectoryClient>(client =>
        {
            client.BaseAddress = new Uri("https://itunes.apple.com/");
        });
        services.AddHttpClient<IPodcastFeedClient, PodcastFeedClient>();

        // Used for every fetch of an untrusted feed-supplied URL (podcast:chapters,
        // podcast:transcript) via PublicResourceFetcher — auto-redirect is disabled so it can see
        // and re-validate every redirect hop itself instead of the runtime following one straight
        // past the SSRF guard. Still inherits the app's HTTP defaults (resilience handler, service
        // discovery, OTel instrumentation) from ConfigureHttpClientDefaults in ServiceDefaults,
        // since that applies to every client the factory creates.
        services.AddHttpClient(PublicResourceFetcher.HttpClientName)
            .ConfigurePrimaryHttpMessageHandler(() => new SocketsHttpHandler { AllowAutoRedirect = false });
        // Stateless — it only holds the injected factory/resolver — so a singleton avoids any
        // captive-dependency concern from the transient PodcastFeedClient taking it as a dependency.
        services.AddSingleton<PublicResourceFetcher>();

        return services;
    }
}
