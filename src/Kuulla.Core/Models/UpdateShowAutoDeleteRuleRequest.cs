namespace Kuulla.Core.Models;

// Both fields nullable: null AutoDeleteRule clears the per-show override (inherit the global rule);
// null AutoDeleteAfterDays clears the per-show day-count override. They're set together so a client
// switching a show to "After N days" can send the rule and its N in one call.
public record UpdateShowAutoDeleteRuleRequest(AutoDeleteRule? AutoDeleteRule, int? AutoDeleteAfterDays);
