using Kuulla.Core.Services;

namespace Kuulla.FeedPoller;

// Dedicated host for the subscribed-podcast episode pull that used to run as an in-process
// BackgroundService in the API (FeedPollingBackgroundService). Splitting it out means the sweep
// runs once per tick regardless of how many API replicas are up (#38). Locally it's a long-lived
// timer loop under Aspire; in production it's published as an Azure Container Apps scheduled job
// on a cron trigger (#414), where the container starts, runs one sweep, and exits — the
// RunOnceThenExit path below covers that.
public class FeedPollingWorker(
    IServiceScopeFactory scopeFactory,
    IConfiguration configuration,
    IHostApplicationLifetime lifetime,
    ILogger<FeedPollingWorker> logger) : BackgroundService
{
    // 15 minutes balances "new episodes get noticed reasonably promptly" against outbound request
    // volume — every subscribed show's feed is refetched on every tick regardless of whether that
    // show has actually published anything new. Configurable (FeedPolling:IntervalMinutes) so a
    // deployed environment can tune it without a code change, and so a local test can drop it low.
    private static readonly TimeSpan DefaultInterval = TimeSpan.FromMinutes(15);

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        // ACA scheduled job (#414): the container exists only to run one sweep, so do exactly that
        // and stop the host — no idle timer keeping the replica (and its billing) alive.
        if (configuration.GetValue<bool>("FeedPolling:RunOnceThenExit"))
        {
            logger.LogInformation("Feed poller running a single sweep (RunOnceThenExit) then exiting");
            await PollOnceAsync(stoppingToken);
            lifetime.StopApplication();
            return;
        }

        // A configured value of 0/negative (or unparsable) would otherwise reach PeriodicTimer's
        // constructor, which throws ArgumentOutOfRangeException for a non-positive interval and
        // would crash the host at startup — validate here and fall back instead.
        var interval = configuration.GetValue<double?>("FeedPolling:IntervalMinutes") is { } minutes && minutes > 0
            ? TimeSpan.FromMinutes(minutes)
            : DefaultInterval;

        logger.LogInformation("Feed poller started; sweeping every {IntervalMinutes} minute(s)", interval.TotalMinutes);

        // Sweep immediately on startup rather than waiting out a full interval first — a restart is
        // then also the way to force a sweep locally.
        await PollOnceAsync(stoppingToken);

        using var timer = new PeriodicTimer(interval);
        while (await timer.WaitForNextTickAsync(stoppingToken))
        {
            await PollOnceAsync(stoppingToken);
        }
    }

    private async Task PollOnceAsync(CancellationToken cancellationToken)
    {
        try
        {
            // IFeedPollingService is scoped (it depends on scoped Cosmos-backed services), so it's
            // resolved through a fresh scope each tick rather than injected directly.
            using var scope = scopeFactory.CreateScope();
            var pollingService = scope.ServiceProvider.GetRequiredService<IFeedPollingService>();
            await pollingService.PollOnceAsync(cancellationToken);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            // A single tick failing outright (e.g. Cosmos unavailable) shouldn't kill the worker
            // for its whole lifetime — log and try again next tick.
            logger.LogError(ex, "Feed polling sweep failed");
        }
    }
}
