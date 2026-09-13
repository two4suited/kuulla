namespace Kuulla.Core.Models;

// Both fields nullable: null AutoDownloadEpisodeLimit clears the per-show limit override (inherit
// the global limit); null AutoDownloadChargingOnly clears the per-show charging-only override.
// Set together, same rationale as UpdateShowAutoDeleteRuleRequest.
public record UpdateShowAutoDownloadRulesRequest(int? AutoDownloadEpisodeLimit, bool? AutoDownloadChargingOnly);
