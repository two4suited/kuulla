import Foundation

// Shared ordering for the subscribed-shows list (#438), applied on both LibraryView and
// SubscriptionsView so one synced setting (UserSettings.subscriptionSortOrder) drives both.
// Mirrors src/Kuulla.Web/Services/SubscriptionSorting.cs.
func sortedSubscriptions(
    _ subscriptions: [Subscription],
    by order: SubscriptionSortOrder,
    manualOrder: [String] = []
) -> [Subscription] {
    switch order {
    case .latestEpisode:
        return subscriptions.sorted { lhs, rhs in
            let lhsDate = lhs.latestEpisodePublishedAt ?? .distantPast
            let rhsDate = rhs.latestEpisodePublishedAt ?? .distantPast
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }
            return lhs.showTitle.localizedCaseInsensitiveCompare(rhs.showTitle) == .orderedAscending
        }
    case .recentlyAdded:
        return subscriptions.sorted { lhs, rhs in
            if lhs.subscribedAt != rhs.subscribedAt {
                return lhs.subscribedAt > rhs.subscribedAt
            }
            return lhs.showTitle.localizedCaseInsensitiveCompare(rhs.showTitle) == .orderedAscending
        }
    case .manual:
        // Shows listed in manualOrder come first in that order; anything not listed (subscribed
        // after the arrangement was saved) falls to the end by title. Unknown ids are ignored.
        var rank: [String: Int] = [:]
        for (i, showId) in manualOrder.enumerated() where rank[showId] == nil {
            rank[showId] = i
        }
        return subscriptions.sorted { lhs, rhs in
            let lhsRank = rank[lhs.showId] ?? Int.max
            let rhsRank = rank[rhs.showId] ?? Int.max
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }
            return lhs.showTitle.localizedCaseInsensitiveCompare(rhs.showTitle) == .orderedAscending
        }
    case .title:
        return subscriptions.sorted {
            $0.showTitle.localizedCaseInsensitiveCompare($1.showTitle) == .orderedAscending
        }
    }
}
