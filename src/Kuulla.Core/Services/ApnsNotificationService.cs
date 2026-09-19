using dotAPNS;
using Kuulla.Core.Models;

namespace Kuulla.Core.Services;

public class ApnsNotificationService(
    IApnsClient apnsClient,
    IDeviceTokenService deviceTokenService,
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

    public async Task<IReadOnlyList<TestPushResult>> SendTestNotificationAsync(
        IReadOnlyList<DeviceToken> tokens, CancellationToken cancellationToken)
    {
        // A user has a handful of devices at most, so no fan-out limit needed. Dead tokens are
        // deliberately not pruned here: a diagnostic shouldn't erase the evidence it's reporting.
        var results = new List<TestPushResult>(tokens.Count);
        foreach (var token in tokens)
        {
            var push = new ApplePush(ApplePushType.Alert)
                .AddToken(token.ApnsToken)
                .AddAlert("Kuulla", "Test notification. Push is working.")
                .AddSound("default");
            if (token.UseSandbox)
            {
                push.SendToDevelopmentServer();
            }

            try
            {
                var response = await apnsClient.SendAsync(push, cancellationToken);
                results.Add(new TestPushResult(
                    token.DeviceId, token.UseSandbox, response.IsSuccessful, response.IsSuccessful ? null : response.ReasonString));
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                logger.LogWarning(ex, "Failed to send test push notification to device {DeviceId}", token.DeviceId);
                results.Add(new TestPushResult(token.DeviceId, token.UseSandbox, false, ex.Message));
            }
        }

        return results;
    }

    private async Task SendAsync(
        DeviceToken token, string showId, string showTitle, string body, IReadOnlyList<Episode> newEpisodes, CancellationToken cancellationToken)
    {
        var push = new ApplePush(ApplePushType.Alert)
            .AddToken(token.ApnsToken)
            .AddAlert(showTitle, body)
            .AddSound("default")
            // content-available lets iOS wake the app in the background to sync the named
            // episode/show, alongside the visible alert — a valid combined alert+background push.
            .AddContentAvailable()
            // showId (and, when there's exactly one new episode, its id) is custom payload data
            // outside the reserved "aps" dictionary — #218's deep-link handler reads this to route
            // a tap straight to the episode/show instead of just opening the app.
            .AddCustomProperty("showId", showId, false);
        if (newEpisodes.Count == 1)
        {
            push.AddCustomProperty("episodeId", newEpisodes[0].Id, false);
        }

        // Sandbox vs. production is per-push in this dotAPNS version, and per-token here: the host
        // can't know which environment a given device's token came from (an Xcode-installed Debug
        // build talks to the production API but holds a sandbox token).
        if (token.UseSandbox)
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

        if (response.IsSuccessful)
        {
            return;
        }

        // The device uninstalled the app, disabled notifications, or Apple otherwise invalidated
        // this token — routine, so logged quietly and pruned so future sends don't keep retrying a
        // dead token. Anything else (bad key, wrong topic, ...) is a config problem worth a warning.
        var tokenIsDead = response.Reason is
            ApnsResponseReason.BadDeviceToken or ApnsResponseReason.Unregistered or ApnsResponseReason.ExpiredToken;
        logger.Log(
            tokenIsDead ? LogLevel.Information : LogLevel.Warning,
            "APNs rejected push to device {DeviceId} (sandbox: {UseSandbox}): {Reason}",
            token.DeviceId, token.UseSandbox, response.ReasonString);

        if (tokenIsDead)
        {
            await deviceTokenService.UnregisterAsync(token.UserId, token.DeviceId, cancellationToken);
        }
    }
}
