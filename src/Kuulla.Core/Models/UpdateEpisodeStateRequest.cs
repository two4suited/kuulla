namespace Kuulla.Core.Models;

public record UpdateEpisodeStateRequest(string ShowId, int PositionSeconds, bool Completed, string? DeviceId);
