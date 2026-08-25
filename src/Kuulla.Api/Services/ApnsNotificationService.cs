using dotAPNS;
using Kuulla.Api.Models;

namespace Kuulla.Api.Services;

// UseSandbox flag: Apple's sandbox and production APNs environments are set per-push
// (ApplePush.SendToDevelopmentServer()) in this package version rather than per-client, so this
// travels alongside the client rather than being baked into IApnsClient's registration.
public record ApnsNotificationServiceOptions(bool UseSandbox);

public class ApnsNotificationService(
    IApnsClient apnsClient,
    IDeviceTokenService deviceTokenService,
    ApnsNotificationServiceOptions options,
    ILogger<ApnsNotificationService> logger) : INotificationService
{
    // Bounded rather than Task.WhenAll's unbounded fan-out — this runs once per subscriber, and
    // EpisodeService.NotifySubscribersAsync itself fans out to up to 20 subscribers concurrently,
    // so an unbounded per-user send here could multiply into a large concurrent-request spike
    // against Apple's APNs endpoint when many subscribers each have several registered devices.
    private const int MaxDegreeOfParallelism = 10;

    public async Task NotifyNewEpisodesAsync(
        IReadOnlyList<DeviceToken> tokens,
        string showId,
        string showTitle,
        IReadOnlyList<Episode> newEpisodes,
        CancellationToken cancellationToken)
    {
        var body = newEpisodes.Count == 1
            ? $"New episode: {newEpisodes[0].Title}"
            : $"{newEpisodes.Count} new episodes";

        await Parallel.ForEachAsync(
            tokens,
            new ParallelOptions { MaxDegreeOfParallelism = MaxDegreeOfParallelism, CancellationToken = cancellationToken },
            (token, ct) => new ValueTask(SendAsync(token, showId, showTitle, body, newEpisodes, ct)));
    }

    private async Task SendAsync(
        DeviceToken token, string showId, string showTitle, string body, IReadOnlyList<Episode> newEpisodes, CancellationToken cancellationToken)
    {
        var push = new ApplePush(ApplePushType.Alert)
            .AddToken(token.ApnsToken)
            .AddAlert(showTitle, body)
            .AddSound("default")
            // showId (and, when there's exactly one new episode, its id) is custom payload data
            // outside the reserved "aps" dictionary — #218's deep-link handler reads this to route
            // a tap straight to the episode/show instead of just opening the app.
            .AddCustomProperty("showId", showId, false);
        if (newEpisodes.Count == 1)
        {
            push.AddCustomProperty("episodeId", newEpisodes[0].Id, false);
        }

        if (options.UseSandbox)
        {
            push.SendToDevelopmentServer();
        }

        ApnsResponse response;
        try
        {
            response = await apnsClient.SendAsync(push, cancellationToken);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            // One device's push failing (network blip, Apple-side error) shouldn't stop the rest
            // of the fan-out to this show's other subscribers/devices.
            logger.LogWarning(ex, "Failed to send push notification to device {DeviceId}", token.DeviceId);
            return;
        }

        if (!response.IsSuccessful && response.Reason is
            ApnsResponseReason.BadDeviceToken or ApnsResponseReason.Unregistered or ApnsResponseReason.ExpiredToken)
        {
            // The device uninstalled the app, disabled notifications, or Apple otherwise
            // invalidated this token — prune it so future sends don't keep retrying a dead token.
            await deviceTokenService.UnregisterAsync(token.UserId, token.DeviceId, cancellationToken);
        }
    }
}
