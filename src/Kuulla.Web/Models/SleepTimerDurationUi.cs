namespace Kuulla.Web.Models;

// Shared display options for the default sleep timer duration selector. The underlying setting
// is a nullable int (minutes) — null means "no default chosen yet". Unlike AutoSkipDurationUi
// (which uses 0 as an in-band "Off" value), the API's update endpoint only ever sets a concrete
// duration — there's no way to clear it back to null — so null/"no default yet" is represented
// as its own literal option in Settings.razor's markup rather than a value returned from here.
// Mirrors the iOS SleepTimerDuration picker options so the two clients offer the same presets.
public static class SleepTimerDurationUi
{
    public static readonly int[] Options = [5, 10, 15, 30, 45, 60, 90];

    // A value saved from elsewhere (or a future release with different presets) that doesn't
    // match one of the options above still needs a representable selection, so it's included
    // alongside the presets rather than silently snapping to the nearest one.
    public static int[] OptionsIncluding(int? currentValue) =>
        currentValue is { } value && !Options.Contains(value) ? [.. Options, value] : Options;

    public static string Format(int minutes) => $"{minutes} min";
}
