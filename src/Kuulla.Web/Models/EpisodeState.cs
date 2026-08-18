namespace Kuulla.Web.Models;

// Web-side mirror of Kuulla.Api.Models.EpisodeState's wire shape.
public record EpisodeState(
    string Id,
    string UserId,
    string EpisodeId,
    string ShowId,
    int PositionSeconds,
    bool Completed,
    DateTimeOffset UpdatedAt,
    string? DeviceId);
