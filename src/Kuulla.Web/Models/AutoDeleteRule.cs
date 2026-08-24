namespace Kuulla.Web.Models;

// Mirrors the API's Kuulla.Api.Models.AutoDeleteRule enum, including its raw values, since the
// wire format is a plain integer. Never is the safe, non-destructive default.
public enum AutoDeleteRule
{
    Never = 0,
    AfterPlayed = 1,
    AfterDays = 2,
}
