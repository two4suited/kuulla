namespace Kuulla.Core.Models;

// AutoDownloadEpisodeLimit and AutoDownloadChargingOnly are set together (#689) — both come from
// the same "Auto-Download Rules" settings section, so one request avoids a client having to make
// two round trips (and two Version bumps) for one logical edit.
public record UpdateAutoDownloadRulesRequest(int AutoDownloadEpisodeLimit, bool AutoDownloadChargingOnly);
