namespace Kuulla.Web.Models;

// Mirrors Kuulla.Api.Models.SubscriptionSortOrder — how the subscribed-shows list is ordered
// on Library/Subscriptions (#438). Title is 0 so it's the default for a settings document that
// predates the field.
public enum SubscriptionSortOrder
{
    Title = 0,
    LatestEpisode = 1,
    RecentlyAdded = 2,
    Manual = 3,
}
