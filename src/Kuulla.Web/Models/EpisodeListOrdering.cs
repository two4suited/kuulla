namespace Kuulla.Web.Models;

public enum EpisodeFilter { All, Unfinished, Unplayed, InProgress }

public enum EpisodeSortOrder { NewestFirst, OldestFirst }

// The show page's episode-list filter and sort as one pure function, shared by ShowDetail.razor
// (what the list shows) and EpisodeDetail.razor (#629 — what plays next when an episode started
// from that list finishes), so both agree on "the show's current sort/filter". Mirrors the iOS
// EpisodeListFilter.apply seam.
//
// `episodes` is expected in the API's own newest-first order. Archived episodes are excluded
// from every filter, including All — auto-archiving hides played episodes from the active list
// entirely (#187).
public static class EpisodeListOrdering
{
    public static List<Episode> Apply(
        IEnumerable<Episode> episodes,
        IReadOnlyDictionary<string, EpisodeState> states,
        EpisodeFilter filter,
        EpisodeSortOrder sort)
    {
        var active = episodes.Where(e => !IsArchived(states.GetValueOrDefault(e.Id)));
        IEnumerable<Episode> filtered = filter switch
        {
            EpisodeFilter.Unfinished => active.Where(e => IsUnplayed(states.GetValueOrDefault(e.Id)) || IsInProgress(states.GetValueOrDefault(e.Id))),
            EpisodeFilter.Unplayed => active.Where(e => IsUnplayed(states.GetValueOrDefault(e.Id))),
            EpisodeFilter.InProgress => active.Where(e => IsInProgress(states.GetValueOrDefault(e.Id))),
            _ => active,
        };

        return (sort == EpisodeSortOrder.OldestFirst ? filtered.Reverse() : filtered).ToList();
    }

    public static bool IsArchived(EpisodeState? state) => state?.Archived == true;

    // Auto-played episodes are treated as played here — they show their own "Auto-marked played"
    // badge with a Restore action, so they shouldn't also clutter the Unplayed filter. Only
    // episodes with no real progress (the shape a Restore write leaves, or no state at all) count
    // as unplayed.
    public static bool IsUnplayed(EpisodeState? state) =>
        state is null || (!state.AutoPlayed && !state.Completed && state.PositionSeconds == 0);

    public static bool IsInProgress(EpisodeState? state) => state is { Completed: false, PositionSeconds: > 0 };
}
