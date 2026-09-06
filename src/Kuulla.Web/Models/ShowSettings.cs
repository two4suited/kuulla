namespace Kuulla.Web.Models;

public record ShowSettings(
    string Id, string UserId, string ShowId, UnlistenedEpisodeCount? UnlistenedEpisodeCount, int Version,
    AutoArchiveRule? AutoArchiveRule = null, bool? AutoDownloadNewEpisodes = null,
    // Null means "no override — inherit the user's global PlaybackSpeed".
    float? PlaybackSpeed = null,
    bool? AutoAddNewEpisodesToUpNext = null);
