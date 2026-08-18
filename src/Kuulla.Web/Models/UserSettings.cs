namespace Kuulla.Web.Models;

public record UserSettings(string UserId, UnlistenedEpisodeCount UnlistenedEpisodeCount, int Version);

public enum UnlistenedEpisodeCount
{
    One = 1,
    Two = 2,
    Five = 5,
    Ten = 10,
    Unlimited = -1,
}
