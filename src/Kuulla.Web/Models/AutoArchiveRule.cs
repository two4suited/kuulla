namespace Kuulla.Web.Models;

// Mirrors the API's Kuulla.Api.Models.AutoArchiveRule enum, including its raw values, since the
// wire format is a plain integer. Never is the safe, non-destructive default.
public enum AutoArchiveRule
{
    Never = 0,
    AfterPlayed = 1,
    After1Day = 2,
    After7Days = 3,
    After30Days = 4,
}
