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
    // Null means "no override — inherit the user's global SmartSpeed".
    bool? SmartSpeed = null,
    bool? AutoAddNewEpisodesToUpNext = null,
    // Null means "no override — inherit the user's global NotificationsEnabled".
    bool? NotificationsEnabled = null);
