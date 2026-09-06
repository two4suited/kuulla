namespace Kuulla.Web.Models;

// Web-side mirror of Kuulla.Api.Models.PlaylistIcons.Curated (#439). Must stay identical to the
// API list and ios/Kuulla/Kuulla/PlaylistIcons.swift so the picker offers the same grid on every
// client. The API is the source of truth and rejects any icon not in its own copy.
public static class PlaylistIcons
{
    public static readonly IReadOnlyList<string> Curated =
    [
        "🎧", "🎵", "🔥", "⭐", "❤️", "🎯", "💪", "🏃",
        "🚗", "🛏️", "☕", "🌙", "☀️", "🧠", "📚", "💼",
        "🎙️", "😂", "📰", "🏛️", "⚽", "🍿", "✈️", "🧘",
    ];

    // Inline style that tints a playlist's icon glyph with its accent colour — empty when the
    // playlist has none. Shared by every surface that renders the glyph so they stay consistent.
    public static string AccentColorStyle(string? accentColor) =>
        string.IsNullOrEmpty(accentColor) ? "" : $"color: {accentColor};";
}
