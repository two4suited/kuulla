using Kuulla.Web.Models;

namespace Kuulla.Web.Services;

// Shared ordering for the subscribed-shows list (#438), applied client-side on both the Library
// (Home.razor) and Subscriptions pages so a single synced setting drives both. Mirrors
// ios/Kuulla/Kuulla/SubscriptionSort.swift.
public static class SubscriptionSorting
{
    public static IReadOnlyList<Subscription> Sort(
        IEnumerable<Subscription> subscriptions,
        SubscriptionSortOrder order,
        IReadOnlyList<string>? manualOrder = null) =>
        order switch
        {
            SubscriptionSortOrder.LatestEpisode => subscriptions
                .OrderByDescending(s => s.LatestEpisodePublishedAt ?? DateTimeOffset.MinValue)
                .ThenBy(s => s.ShowTitle, StringComparer.OrdinalIgnoreCase)
                .ToList(),
            SubscriptionSortOrder.RecentlyAdded => subscriptions
                .OrderByDescending(s => s.SubscribedAt)
                .ThenBy(s => s.ShowTitle, StringComparer.OrdinalIgnoreCase)
                .ToList(),
            SubscriptionSortOrder.Manual => SortManual(subscriptions, manualOrder),
            _ => subscriptions
                .OrderBy(s => s.ShowTitle, StringComparer.OrdinalIgnoreCase)
                .ToList(),
        };

    // Applies a drag-reorder to the currently displayed order and returns the new full showId
    // array to persist (#438 Manual mode), or null when the move is a no-op / out of range.
    // Shared by Home.razor and Subscriptions.razor so the reorder math lives in one place.
    public static IReadOnlyList<string>? ApplyManualMove(
        IReadOnlyList<Subscription> orderedView, int fromIndex, int toIndex)
    {
        if (fromIndex == toIndex ||
            fromIndex < 0 || fromIndex >= orderedView.Count ||
            toIndex < 0 || toIndex >= orderedView.Count)
        {
            return null;
        }

        var ids = orderedView.Select(s => s.ShowId).ToList();
        var moved = ids[fromIndex];
        ids.RemoveAt(fromIndex);
        ids.Insert(toIndex, moved);
        return ids;
    }

    // Shows listed in manualOrder come first, in that order; anything not listed (a show
    // subscribed to after the arrangement was last saved) falls to the end sorted by title.
    // Ids in manualOrder that are no longer subscribed to are simply skipped.
    private static IReadOnlyList<Subscription> SortManual(
        IEnumerable<Subscription> subscriptions, IReadOnlyList<string>? manualOrder)
    {
        var byShowId = subscriptions.ToDictionary(s => s.ShowId);
        var rank = new Dictionary<string, int>(StringComparer.Ordinal);
        if (manualOrder is not null)
        {
            for (var i = 0; i < manualOrder.Count; i++)
            {
                rank.TryAdd(manualOrder[i], i);
            }
        }

        return byShowId.Values
            .OrderBy(s => rank.TryGetValue(s.ShowId, out var r) ? r : int.MaxValue)
            .ThenBy(s => s.ShowTitle, StringComparer.OrdinalIgnoreCase)
            .ToList();
    }
}
