using Kuulla.Core.Models;

namespace Kuulla.Core.Services;

// Registered instead of ApnsNotificationService when Apns:KeyId/TeamId/BundleId/PrivateKey
// aren't configured — a startup warning (Program.cs, mirroring the Google OAuth credentials
// check) covers telling the operator once; every call here is then a silent no-op rather than a
// per-request warning, and rather than making every caller null-check whether push is enabled.
public class NoOpNotificationService : INotificationService
{
    public Task NotifyNewEpisodesAsync(
        IReadOnlyList<DeviceToken> tokens,
        string showId,
        string showTitle,
        IReadOnlyList<Episode> newEpisodes,
        CancellationToken cancellationToken) => Task.CompletedTask;

    public Task<IReadOnlyList<TestPushResult>> SendTestNotificationAsync(
        IReadOnlyList<DeviceToken> tokens, CancellationToken cancellationToken) =>
        Task.FromResult<IReadOnlyList<TestPushResult>>(
            tokens.Select(t => new TestPushResult(t.DeviceId, t.UseSandbox, false, "APNs is not configured on the server")).ToList());
}
