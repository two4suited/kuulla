namespace Kuulla.Web.Models;

// Shared display options for the AutoDeleteRule selector — used by the global settings page and
// the per-show override on the show page (#445).
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
