namespace Kuulla.Core.Services;

// Bound from configuration (FeedPolling:MaxDegreeOfParallelism, env var override
// FeedPolling__MaxDegreeOfParallelism) so the outer sweep's concurrency can be tuned
// per-environment — including a deployed Azure Container Apps job — without a code change +
// redeploy (#597).
public class FeedPollingOptions
{
    // Bounds FeedPollingService's *outer* degree of concurrency: each show polled there can
    // itself spawn up to CacheEpisodesAsync's own internal fan-out (5, lowered from 20 in #558)
    // worth of concurrent Cosmos writes/enforcement calls. Default of 15 (raised from 5 in #596)
    // reflects #579's conditional-GET + watermark short-circuit making most polls skip
    // CacheEpisodesAsync's Cosmos fan-out entirely — a production sweep at 5 showed 0% Cosmos
    // throttling and ~36 RU/show, meaning outbound HTTP to feed servers, not Cosmos, was the
    // bottleneck. Revisit if Cosmos throttling reappears.
    public int MaxDegreeOfParallelism { get; set; } = 15;
}
