namespace Kuulla.Core.Models;

public record UpdateAutoDeleteRuleRequest(AutoDeleteRule AutoDeleteRule, int AutoDeleteAfterDays);
