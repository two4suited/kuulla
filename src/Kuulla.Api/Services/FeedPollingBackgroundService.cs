namespace Kuulla.Api.Services;

// The API's first scheduled/background job (see the Spike issue #215) — everything else that
// touches a show's feed today (EpisodeService.GetEpisodesAsync/GetEpisodeAsync) is client-driven,
// only refetching when some user happens to open that show. A subscriber who never opens the app
// would otherwise never get a new episode cached — or, via #216, a push notification — until they
// did. Registered as a singleton IHostedService, so IFeedPollingService (scoped, since it depends
// on scoped Cosmos-backed services) is resolved through a fresh scope each tick rather than
// injected directly.
public class FeedPollingBackgroundService(
    IServiceScopeFactory scopeFactory, IConfiguration configuration, ILogger<FeedPollingBackgroundService> logger)
    : BackgroundService
{
    // 15 minutes balances "new episodes get noticed reasonably promptly" against outbound request
    // volume — every subscribed show's feed is refetched on every tick regardless of whether that
    // show has actually published anything new. Configurable (FeedPolling:IntervalMinutes) so a
    // deployed environment can tune it without a code change.
    private static readonly TimeSpan DefaultInterval = TimeSpan.FromMinutes(15);

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        var interval = configuration.GetValue<double?>("FeedPolling:IntervalMinutes") is { } minutes
            ? TimeSpan.FromMinutes(minutes)
            : DefaultInterval;

        using var timer = new PeriodicTimer(interval);
        do
        {
            try
            {
                using var scope = scopeFactory.CreateScope();
                var pollingService = scope.ServiceProvider.GetRequiredService<IFeedPollingService>();
                await pollingService.PollOnceAsync(stoppingToken);
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                // A single tick failing outright (e.g. Cosmos unavailable) shouldn't kill the
                // background service for the app's whole lifetime — log and try again next tick.
                logger.LogError(ex, "Feed polling sweep failed");
            }
        } while (await timer.WaitForNextTickAsync(stoppingToken));
    }
}
