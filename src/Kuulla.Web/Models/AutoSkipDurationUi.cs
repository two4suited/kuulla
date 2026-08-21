namespace Kuulla.Web.Models;

// Shared display options for the auto-skip intro/outro selectors. The underlying setting is a
// plain int (seconds), so these are just the commonly-useful presets surfaced in the UI,
// mirroring the iOS AutoSkipDuration picker options so the two clients offer the same choices.
public static class AutoSkipDurationUi
{
    public static readonly int[] Options = [0, 5, 10, 15, 20, 30, 45, 60];

    // A value saved from elsewhere (or a future release with different presets) that doesn't
    // match one of the options above still needs a representable selection, so it's included
    // alongside the presets rather than silently snapping to the nearest one.
    public static int[] OptionsIncluding(int currentValue) =>
        Options.Contains(currentValue) ? Options : [.. Options, currentValue];

    public static string Format(int seconds) => seconds == 0 ? "Off" : $"{seconds}s";
}
