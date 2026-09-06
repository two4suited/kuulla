using System.Text.RegularExpressions;

namespace Kuulla.Core.Models;

// The curated set of playlist icons (#439). A playlist's Icon is a stable identifier the server
// controls, not free-form user input, so it renders consistently on every client. We store an
// emoji directly (rather than a symbolic name that each client maps to an SF Symbol / Bootstrap
// icon) because emoji render natively and identically on web and iOS with no per-client mapping
// table to keep in sync — the trade-off the issue explicitly allows ("an emoji, or a name that
// maps to...").
// A null Icon means "no icon" — the client falls back to its existing default playlist glyph.
// The Web (src/Kuulla.Web/Models/PlaylistIcons.cs) and iOS (ios/Kuulla/Kuulla/PlaylistIcons.swift)
// mirrors of this list must be kept identical, so the picker on every client offers the same grid.
public static partial class PlaylistIcons
{
    public static readonly IReadOnlyList<string> Curated =
    [
        "🎧", "🎵", "🔥", "⭐", "❤️", "🎯", "💪", "🏃",
        "🚗", "🛏️", "☕", "🌙", "☀️", "🧠", "📚", "💼",
        "🎙️", "😂", "📰", "🏛️", "⚽", "🍿", "✈️", "🧘",
    ];

    private static readonly HashSet<string> CuratedSet = [.. Curated];

    // A null/empty icon is valid (it clears the icon); any non-empty value must be one we curate.
    public static bool IsValidIcon(string? icon) =>
        string.IsNullOrEmpty(icon) || CuratedSet.Contains(icon);

    // A null/empty accent colour is valid (it clears it); otherwise it must be a #RRGGBB hex
    // string. Kept as free-form hex rather than a curated palette so clients can offer their own
    // swatches without a server round-trip to add one.
    public static bool IsValidAccentColor(string? accentColor) =>
        string.IsNullOrEmpty(accentColor) || AccentColorPattern().IsMatch(accentColor);

    [GeneratedRegex("^#[0-9A-Fa-f]{6}$")]
    private static partial Regex AccentColorPattern();
}
