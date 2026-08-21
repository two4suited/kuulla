namespace Kuulla.Web.Models;

public record UserSettings(string UserId, UnlistenedEpisodeCount UnlistenedEpisodeCount, int Version, AutoArchiveRule AutoArchiveRule = AutoArchiveRule.Never);

public enum UnlistenedEpisodeCount
{
    One = 1,
    Two = 2,
    Five = 5,
    Ten = 10,
    Unlimited = -1,
}
