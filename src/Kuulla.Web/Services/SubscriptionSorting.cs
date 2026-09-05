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
