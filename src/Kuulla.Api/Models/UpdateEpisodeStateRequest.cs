namespace Kuulla.Api.Models;

public record UpdateEpisodeStateRequest(string ShowId, int PositionSeconds, bool Completed, string? DeviceId);
