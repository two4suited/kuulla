namespace Kuulla.Web.Models;

// Shared display options for the playback speed selector. The underlying setting is a plain
// float (0.5...3.0 in 0.1 increments, validated API-side), so these are just the
// commonly-useful presets surfaced in the UI, mirroring the iOS PlaybackSpeedOption picker
// options so the two clients offer the same choices.
public static class PlaybackSpeedUi
{
    public static readonly float[] Options = [0.5f, 0.7f, 0.8f, 1.0f, 1.2f, 1.5f, 1.8f, 2.0f, 2.5f, 3.0f];

    // A value saved from elsewhere (or a future release with different presets) that doesn't
    // match one of the options above still needs a representable selection, so it's included
    // alongside the presets rather than silently snapping to the nearest one.
    public static float[] OptionsIncluding(float currentValue) =>
        Options.Contains(currentValue) ? Options : [.. Options, currentValue];

    public static string Format(float speed) => $"{speed.ToString("0.##", System.Globalization.CultureInfo.InvariantCulture)}x";
}
