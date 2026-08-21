namespace Kuulla.Api.Models;

// When to auto-archive a played episode (hide it from the active episode list). Archiving is
// purely a visibility concern here — it does not delete downloads; that's separate follow-up
// work tracked against Downloads & Storage settings (#187).
// AfterPlayed archives immediately once an episode is marked played (manually or automatically);
// the AfterNDays variants delay archiving that many days past when the episode was played, so a
// recently-finished episode still has a grace window to reappear (e.g. to re-share or re-queue)
// before it's hidden.
public enum AutoArchiveRule
{
    Never = 0,
    AfterPlayed = 1,
    After1Day = 2,
    After7Days = 3,
    After30Days = 4,
}

public static class AutoArchiveRuleExtensions
{
    // How long after PlayedAt an episode becomes eligible for archiving under this rule.
    // Never is not meaningful as a delay (callers must special-case it and skip enforcement
    // entirely), so it intentionally has no case here.
    public static TimeSpan ArchiveDelay(this AutoArchiveRule rule) => rule switch
    {
        AutoArchiveRule.AfterPlayed => TimeSpan.Zero,
        AutoArchiveRule.After1Day => TimeSpan.FromDays(1),
        AutoArchiveRule.After7Days => TimeSpan.FromDays(7),
        AutoArchiveRule.After30Days => TimeSpan.FromDays(30),
        _ => throw new ArgumentOutOfRangeException(nameof(rule), rule, $"{nameof(AutoArchiveRule.Never)} has no archive delay."),
    };
}
