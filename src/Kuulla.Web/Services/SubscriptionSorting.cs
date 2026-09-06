using Kuulla.Web.Models;

namespace Kuulla.Web.Services;

// Shared ordering for the subscribed-shows list (#438), applied client-side on both the Library
// (Home.razor) and Subscriptions pages so a single synced setting drives both. Mirrors
// ios/Kuulla/Kuulla/SubscriptionSort.swift.
public static class SubscriptionSorting
{
    // activeShowIds is the set of subscribed show ids that have at least one unplayed or
    // in-progress episode — i.e. the shows the user is NOT caught up on. It's null until the
    // caller has loaded episode state; while null, neither the hide filter nor the
    // latest-episode sink is applied (every show is treated as active). When hideCaughtUp is
    // set, caught-up shows are dropped entirely — except under Manual order, which is a
    // deliberate hand-curated arrangement and always shows every subscribed show.
    public static IReadOnlyList<Subscription> Sort(
        IEnumerable<Subscription> subscriptions,
        SubscriptionSortOrder order,
        IReadOnlyList<string>? manualOrder = null,
        IReadOnlySet<string>? activeShowIds = null,
        bool hideCaughtUp = false)
    {
        var items = subscriptions;
        if (activeShowIds is not null && hideCaughtUp && order != SubscriptionSortOrder.Manual)
        {
            items = items.Where(s => activeShowIds.Contains(s.ShowId));
        }

        return order switch
        {
            // Caught-up shows (not in activeShowIds) sink below active ones — "latest episode"
            // is really "latest unplayed episode", so a show you've finished shouldn't jump the
            // queue on a new episode you've already played. A constant key when activeShowIds is
            // null leaves the ordering untouched.
            SubscriptionSortOrder.LatestEpisode => items
                .OrderByDescending(s => activeShowIds is null || activeShowIds.Contains(s.ShowId))
                .ThenByDescending(s => s.LatestEpisodePublishedAt ?? DateTimeOffset.MinValue)
                .ThenBy(s => s.ShowTitle, StringComparer.OrdinalIgnoreCase)
                .ToList(),
            SubscriptionSortOrder.RecentlyAdded => items
                .OrderByDescending(s => s.SubscribedAt)
                .ThenBy(s => s.ShowTitle, StringComparer.OrdinalIgnoreCase)
                .ToList(),
            SubscriptionSortOrder.Manual => SortManual(items, manualOrder),
            _ => items
                .OrderBy(s => s.ShowTitle, StringComparer.OrdinalIgnoreCase)
                .ToList(),
        };
    }

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
