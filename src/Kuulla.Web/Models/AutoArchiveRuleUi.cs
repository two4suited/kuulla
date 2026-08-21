namespace Kuulla.Web.Models;

// Shared display options for the AutoArchiveRule selector on both the global settings page and
// a show's per-show override, so the two stay in sync when a value is added or a label changes.
public static class AutoArchiveRuleUi
{
    public static readonly AutoArchiveRule[] Options =
    [
        AutoArchiveRule.Never,
        AutoArchiveRule.AfterPlayed,
        AutoArchiveRule.After1Day,
        AutoArchiveRule.After7Days,
        AutoArchiveRule.After30Days,
    ];

    public static string Format(AutoArchiveRule option) => option switch
    {
        AutoArchiveRule.Never => "Never",
        AutoArchiveRule.AfterPlayed => "Immediately after played",
        AutoArchiveRule.After1Day => "1 day after played",
        AutoArchiveRule.After7Days => "7 days after played",
        AutoArchiveRule.After30Days => "30 days after played",
        _ => option.ToString(),
    };
}
