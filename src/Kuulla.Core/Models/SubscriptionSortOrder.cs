namespace Kuulla.Core.Models;

// How the subscribed-shows list is ordered on the Library and Subscriptions surfaces (#438).
// Persisted on UserSettings and synced across devices. Title is 0 so it's the zero-value
// default for an existing settings document that predates this field — matching the Library's
// historical "sorted by title" behavior.
public enum SubscriptionSortOrder
{
    Title = 0,
    LatestEpisode = 1,
    RecentlyAdded = 2,
    Manual = 3,
}
