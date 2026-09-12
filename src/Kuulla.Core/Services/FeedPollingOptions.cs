namespace Kuulla.Core.Services;

// Bound from configuration (FeedPolling:MaxDegreeOfParallelism, env var override
// FeedPolling__MaxDegreeOfParallelism) so the outer sweep's concurrency can be tuned
// per-environment — including a deployed Azure Container Apps job — without a code change +
// redeploy (#597).
public class FeedPollingOptions
{
    // Bounds FeedPollingService's *outer* degree of concurrency: each show polled there can
    // itself spawn up to CacheEpisodesAsync's own internal fan-out (5, lowered from 20 in #558)
    // worth of concurrent Cosmos writes/enforcement calls. Raised 15 -> 100 to push further past
    // outbound HTTP to feed servers (not Cosmos) being the bottleneck identified in #596/#579 —
    // #596's sweep at 5 showed 0% Cosmos throttling and ~36 RU/show. Revisit if Cosmos throttling
    // reappears.
    public int MaxDegreeOfParallelism { get; set; } = 100;
}
