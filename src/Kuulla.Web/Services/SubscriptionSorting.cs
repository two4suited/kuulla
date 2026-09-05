using Kuulla.Web.Models;

namespace Kuulla.Web.Services;

// Shared ordering for the subscribed-shows list (#438), applied client-side on both the Library
// (Home.razor) and Subscriptions pages so a single synced setting drives both. Mirrors
// ios/Kuulla/Kuulla/SubscriptionSort.swift.
public static class SubscriptionSorting
{
    public static IReadOnlyList<Subscription> Sort(IEnumerable<Subscription> subscriptions, SubscriptionSortOrder order) =>
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
            // Manual ordering ships in a follow-up (#438 PR 2); until then it renders as Title.
            _ => subscriptions
                .OrderBy(s => s.ShowTitle, StringComparer.OrdinalIgnoreCase)
                .ToList(),
        };
}
