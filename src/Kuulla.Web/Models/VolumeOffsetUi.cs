namespace Kuulla.Web.Models;

// Shared display options for the volume offset selector (#708). The underlying setting is a
// plain float in dB (-12...12, validated API-side), so these are just the commonly-useful
// presets surfaced in the UI, mirroring the iOS VolumeOffsetOption picker options so the two
// clients offer the same choices.
public static class VolumeOffsetUi
{
    public static readonly float[] Options = [-12f, -9f, -6f, -3f, 0f, 3f, 6f, 9f, 12f];

    // A value saved from elsewhere (or a future release with different presets) that doesn't
    // match one of the options above still needs a representable selection, so it's included
    // alongside the presets rather than silently snapping to the nearest one.
    public static float[] OptionsIncluding(float currentValue) =>
        Options.Contains(currentValue) ? Options : [.. Options, currentValue];

    public static string Format(float volumeOffsetDb) =>
        volumeOffsetDb == 0f
            ? "Off"
            : $"{(volumeOffsetDb > 0 ? "+" : "")}{volumeOffsetDb.ToString("0.#", System.Globalization.CultureInfo.InvariantCulture)} dB";
}
