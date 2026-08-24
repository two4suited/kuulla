namespace Kuulla.Web.Models;

public record UserSettings(
    string UserId,
    UnlistenedEpisodeCount UnlistenedEpisodeCount,
    int Version,
    AutoArchiveRule AutoArchiveRule = AutoArchiveRule.Never,
    int AutoSkipIntroSeconds = 0,
    int AutoSkipOutroSeconds = 0,
    float PlaybackSpeed = 1.0f,
    AutoDeleteRule AutoDeleteRule = AutoDeleteRule.Never,
    int AutoDeleteAfterDays = 7,
    bool AutoDownloadNewEpisodes = false);

public enum UnlistenedEpisodeCount
{
    One = 1,
    Two = 2,
    Five = 5,
    Ten = 10,
    Unlimited = -1,
}
