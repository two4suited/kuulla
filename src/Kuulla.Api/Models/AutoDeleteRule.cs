namespace Kuulla.Api.Models;

// When to delete a downloaded episode's local file (#180's Offline Downloads milestone).
// Never is the safe, non-destructive default — silently deleting a file a user downloaded on
// purpose is a surprising, hard-to-undo action to take without opt-in, same rationale as
// AutoArchiveRule.Never. AfterPlayed fires on the same completion signal that marks an episode
// played (excluding auto-played episodes, so a #100 "Restore" undo doesn't point at a deleted
// file). AfterDays is independent of played state, using AutoDeleteAfterDays rather than a fixed
// set of cases since it needs an arbitrary day count.
public enum AutoDeleteRule
{
    Never = 0,
    AfterPlayed = 1,
    AfterDays = 2,
}
