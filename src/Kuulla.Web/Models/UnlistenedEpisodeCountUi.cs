namespace Kuulla.Web.Models;

// Shared display options for the UnlistenedEpisodeCount selector on both the global settings
// page and a show's per-show override, so the two stay in sync when a value is added or a
// label changes.
public static class UnlistenedEpisodeCountUi
{
    public static readonly UnlistenedEpisodeCount[] Options =
    [
        UnlistenedEpisodeCount.One,
        UnlistenedEpisodeCount.Two,
        UnlistenedEpisodeCount.Five,
        UnlistenedEpisodeCount.Ten,
        UnlistenedEpisodeCount.Unlimited,
    ];

    public static string Format(UnlistenedEpisodeCount option) =>
        option == UnlistenedEpisodeCount.Unlimited ? "Unlimited" : ((int)option).ToString();
}
