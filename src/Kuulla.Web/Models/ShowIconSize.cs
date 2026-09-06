namespace Kuulla.Web.Models;

// How large the show-artwork tiles render in the Library (Home.razor) and Subscriptions grids.
// Device-local (browser localStorage) — how many shows you want per row on this screen says
// nothing about your other devices, so this never round-trips through UserSettings, the same way
// Settings.razor's wifiOnlyStreaming toggle doesn't. Large matches the grid that shipped before
// this option existed. Mirrors ios/Kuulla/Kuulla/ShowIconSize.swift (#452).
public enum ShowIconSize
{
    Small,
    Medium,
    Large,
}

public static class ShowIconSizes
{
    // localStorage key shared by every ShowIconSizeSelect instance so the Library and
    // Subscriptions grids stay in sync from a single stored value.
    public const string StorageKey = "showIconSize";

    public static readonly ShowIconSize Default = ShowIconSize.Large;

    public static readonly IReadOnlyList<ShowIconSize> All =
        [ShowIconSize.Small, ShowIconSize.Medium, ShowIconSize.Large];

    public static string Label(this ShowIconSize size) => size switch
    {
        ShowIconSize.Small => "Small",
        ShowIconSize.Medium => "Medium",
        _ => "Large",
    };

    // Bootstrap row-cols classes for the grid wrapper. Large keeps the original
    // "row-cols-2 row-cols-md-4"; smaller sizes fit more shows per row (md capped at 8, per #447).
    public static string RowColsClass(this ShowIconSize size) => size switch
    {
        ShowIconSize.Small => "row-cols-4 row-cols-md-8",
        ShowIconSize.Medium => "row-cols-3 row-cols-md-6",
        _ => "row-cols-2 row-cols-md-4",
    };

    // Resolves a stored localStorage string back to a case, tolerating a missing or stale value.
    public static ShowIconSize Parse(string? raw) =>
        Enum.TryParse<ShowIconSize>(raw, ignoreCase: true, out var size) && Enum.IsDefined(size)
            ? size
            : Default;

    public static string ToStorageString(this ShowIconSize size) => size.ToString();
}
