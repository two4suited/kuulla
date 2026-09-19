using dotAPNS;
using Kuulla.Core.Services;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;

namespace Kuulla.Core;

// Push-notification wiring shared by every host that runs EpisodeService.CacheEpisodesAsync (the
// API and the Kuulla.FeedPoller worker) — both need an INotificationService in the container
// because EpisodeService takes one, and both send the *same* new-episode push. Kept out of
// AddKuullaCore because it needs IConfiguration and the host's environment (sandbox vs.
// production APNs) rather than being a pure service-graph registration.
public static class NotificationServiceCollectionExtensions
{
    // APNs credentials (milestone #32, issue #216) are optional: push is additive infrastructure,
    // not something local dev or CI needs configured. Falls back to a no-op sender (with a
    // one-time startup warning) when any of the four values is unset, rather than failing startup.
    // Sandbox vs. production APNs is chosen per device token (DeviceToken.UseSandbox), not per
    // host: a debug-signed build's tokens are only valid on Apple's sandbox environment even when
    // they're registered with the production API.
    public static IServiceCollection AddKuullaNotifications(
        this IServiceCollection services, IConfiguration configuration)
    {
        var apnsKeyId = configuration["Apns:KeyId"];
        var apnsTeamId = configuration["Apns:TeamId"];
        var apnsBundleId = configuration["Apns:BundleId"];
        var apnsPrivateKey = configuration["Apns:PrivateKey"];

        if (string.IsNullOrEmpty(apnsKeyId) || string.IsNullOrEmpty(apnsTeamId)
            || string.IsNullOrEmpty(apnsBundleId) || string.IsNullOrEmpty(apnsPrivateKey))
        {
            Console.WriteLine(
                "warn: APNs not configured ('Apns:KeyId'/'Apns:TeamId'/'Apns:BundleId'/'Apns:PrivateKey') " +
                "— push notifications are disabled; new-episode pushes will be silently skipped.");
            services.AddScoped<INotificationService, NoOpNotificationService>();
            return services;
        }

        services.AddHttpClient("apns");
        services.AddSingleton<IApnsClient>(sp =>
        {
            var httpClient = sp.GetRequiredService<IHttpClientFactory>().CreateClient("apns");
            return ApnsClient.CreateUsingJwt(httpClient, new ApnsJwtOptions
            {
                CertContent = apnsPrivateKey,
                KeyId = apnsKeyId,
                TeamId = apnsTeamId,
                BundleId = apnsBundleId,
            });
        });
        services.AddScoped<INotificationService, ApnsNotificationService>();
        return services;
    }
}
