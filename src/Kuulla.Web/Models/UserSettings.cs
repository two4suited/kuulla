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
    bool AutoDownloadNewEpisodes = false,
    bool SmartSpeed = false,
    // Normalizes loudness across episodes (#679), independent of SmartSpeed's silence-trimming.
    bool VoiceBoost = false,
    int? SleepTimerDefaultDurationMinutes = null,
    SubscriptionSortOrder SubscriptionSortOrder = SubscriptionSortOrder.Title,
    IReadOnlyList<string>? SubscriptionManualOrder = null,
    bool HideCaughtUpShows = false,
    bool AutoAddNewEpisodesToUpNext = false,
    UpNextInsertPosition UpNextInsertPosition = UpNextInsertPosition.Bottom,
    // What plays when an episode finishes (#629). Web-side mirror of
    // Kuulla.Core.Models.UserSettings.PlayNextBehavior; NextInList is the API's default.
    PlayNextBehavior PlayNextBehavior = PlayNextBehavior.NextInList,
    DateTimeOffset UpdatedAt = default,
    string? DeviceId = null);

public enum UnlistenedEpisodeCount
{
    One = 1,
    Two = 2,
    Five = 5,
    Ten = 10,
    Unlimited = -1,
}

public enum UpNextInsertPosition
{
    Bottom,
    Top,
}

// Web-side mirror of Kuulla.Core.Models.PlayNextBehavior (#629): what plays when an episode
// finishes — the next item of the list playback was started from, that list's first item, or
// nothing. Values must match the API's, since the wire format is the enum's integer.
public enum PlayNextBehavior
{
    NextInList,
    TopOfList,
    Stop,
}
