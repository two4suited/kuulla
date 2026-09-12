namespace Kuulla.Web.Models;

// One entry of the list playback was started from (#629) — enough to build the next episode's URL.
public readonly record struct PlaybackListItem(string ShowId, string EpisodeId);

// The pure "what plays next" decisions for #629, pulled out of EpisodeDetail.razor so they're unit
// testable without a rendered component. Mirrors PlaybackQueue.nextItem(after:in:behavior:) on
// iOS — the two must agree, since a user can finish the same list on either client.
public static class PlayNext
{
    // Resolution order: playlist override → show override → global. When playback was started
    // from a playlist, the playlist wins over the finished episode's show because the user is
    // explicitly listening to that list.
    public static PlayNextBehavior Resolve(
        PlayNextBehavior? playlistOverride, PlayNextBehavior? showOverride, PlayNextBehavior global) =>
        playlistOverride ?? showOverride ?? global;

    // The item to start after `finishedEpisodeId`, or null to stop. NextInList: the following
    // item, or null at the end of the list — or when the finished episode isn't in the snapshot
    // at all (a reorder/removal race), which is likewise "stop" rather than a guess. TopOfList:
    // the first item that isn't the one that just finished (the list may or may not have dropped
    // it yet), so an exhausted single-item list also stops.
    public static PlaybackListItem? NextItem(
        string finishedEpisodeId, IReadOnlyList<PlaybackListItem> items, PlayNextBehavior behavior)
    {
        switch (behavior)
        {
            case PlayNextBehavior.Stop:
                return null;
            case PlayNextBehavior.TopOfList:
                foreach (var item in items)
                {
                    if (item.EpisodeId != finishedEpisodeId)
                    {
                        return item;
                    }
                }

                return null;
            default:
                for (var i = 0; i < items.Count; i++)
                {
                    if (items[i].EpisodeId == finishedEpisodeId)
                    {
                        return i + 1 < items.Count ? items[i + 1] : null;
                    }
                }

                return null;
        }
    }
}

// The query string an episode link carries so EpisodeDetail.razor knows which list it was opened
// from (#629): `list=show` (plus the show page's current filter/sort — the show id is already in
// the route), `list=playlist&listId=…` (manual, dynamic or Up Next), or `list=new` (New
// Episodes). Building them here keeps every list page and EpisodeDetail's parser in one place.
public static class PlaybackListQuery
{
    public const string ShowList = "show";
    public const string PlaylistList = "playlist";
    public const string NewEpisodesList = "new";

    public static string ForShow(EpisodeFilter filter, EpisodeSortOrder sort) =>
        $"?list={ShowList}&filter={filter}&sort={sort}";

    public static string ForPlaylist(string playlistId) =>
        $"?list={PlaylistList}&listId={Uri.EscapeDataString(playlistId)}";

    public static string ForNewEpisodes() => $"?list={NewEpisodesList}";
}
