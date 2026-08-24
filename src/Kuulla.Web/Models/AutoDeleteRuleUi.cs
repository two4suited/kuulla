namespace Kuulla.Web.Models;

// Shared display options for the AutoDeleteRule selector on the global settings page — no
// per-show override exists for this field (global only, per docs/downloads-storage-settings.md).
public static class AutoDeleteRuleUi
{
    public static readonly AutoDeleteRule[] Options =
    [
        AutoDeleteRule.Never,
        AutoDeleteRule.AfterPlayed,
        AutoDeleteRule.AfterDays,
    ];

    public static string Format(AutoDeleteRule option) => option switch
    {
        AutoDeleteRule.Never => "Never",
        AutoDeleteRule.AfterPlayed => "After played",
        AutoDeleteRule.AfterDays => "After N days",
        _ => option.ToString(),
    };
}
