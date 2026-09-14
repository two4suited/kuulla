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
    // Null means "no override — inherit the user's global VoiceBoost" (#679).
    bool? VoiceBoost = null,
    // Null means "no override — inherit the user's global TrimSilence" (#680).
    bool? TrimSilence = null,
    bool? AutoAddNewEpisodesToUpNext = null,
    // Null means "no override — inherit the user's global UpNextInsertPosition".
    UpNextInsertPosition? UpNextInsertPosition = null,
    // Null means "no override — inherit the user's global NotificationsEnabled".
    bool? NotificationsEnabled = null,
    // Null means "no override — inherit the user's global PlayNextBehavior" (#629).
    PlayNextBehavior? PlayNextBehavior = null,
    // Null means "no override — inherit the user's global VolumeOffsetDb" (#708).
    float? VolumeOffsetDb = null);
