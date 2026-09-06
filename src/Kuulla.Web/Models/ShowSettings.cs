namespace Kuulla.Web.Models;

public record ShowSettings(
    string Id, string UserId, string ShowId, UnlistenedEpisodeCount? UnlistenedEpisodeCount, int Version,
    AutoArchiveRule? AutoArchiveRule = null, bool? AutoDownloadNewEpisodes = null,
    bool? AutoAddNewEpisodesToUpNext = null);
