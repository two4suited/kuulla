namespace Kuulla.Web.Models;

public record ShowSettings(
    string Id, string UserId, string ShowId, UnlistenedEpisodeCount? UnlistenedEpisodeCount, int Version,
    AutoArchiveRule? AutoArchiveRule = null,
    // Null means "no override — inherit the user's global AutoSkipIntroSeconds/AutoSkipOutroSeconds".
    int? AutoSkipIntroSeconds = null,
    int? AutoSkipOutroSeconds = null,
    // Null means "no override — inherit the user's global PlaybackSpeed".
    float? PlaybackSpeed = null,
    bool? AutoDownloadNewEpisodes = null,
    // Null means "no override — inherit the user's global AutoDeleteRule / AutoDeleteAfterDays".
    AutoDeleteRule? AutoDeleteRule = null,
    int? AutoDeleteAfterDays = null,
    // Null means "no override — inherit the user's global SmartSpeed".
    bool? SmartSpeed = null,
    bool? AutoAddNewEpisodesToUpNext = null,
    // Null means "no override — inherit the user's global UpNextInsertPosition".
    UpNextInsertPosition? UpNextInsertPosition = null,
    // Null means "no override — inherit the user's global NotificationsEnabled".
    bool? NotificationsEnabled = null,
    // Null means "no override — inherit the user's global PlayNextBehavior" (#629).
    PlayNextBehavior? PlayNextBehavior = null);
