using Kuulla.Api.Models;

namespace Kuulla.Api.Services;

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
}
