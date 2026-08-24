namespace Kuulla.Api.Models;

public record UpdateAutoDeleteRuleRequest(AutoDeleteRule AutoDeleteRule, int AutoDeleteAfterDays);
