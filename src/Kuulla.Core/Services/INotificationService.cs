using Kuulla.Core.Models;

namespace Kuulla.Core.Services;

public interface INotificationService
{
    // One push per device token. showTitle/newEpisodes drive the alert text; showId (and,
    // when there's exactly one new episode, that episode's id) ride along as custom payload
    // data for #218's deep-link handling.
    Task NotifyNewEpisodesAsync(
        IReadOnlyList<DeviceToken> tokens,
        string showId,
        string showTitle,
        IReadOnlyList<Episode> newEpisodes,
        CancellationToken cancellationToken);

    // A fixed "test" alert to each of a user's own devices, for diagnosing why pushes aren't
    // arriving. Reports per-device outcomes instead of swallowing failures like the fan-out above.
    Task<IReadOnlyList<TestPushResult>> SendTestNotificationAsync(
        IReadOnlyList<DeviceToken> tokens, CancellationToken cancellationToken);
}
