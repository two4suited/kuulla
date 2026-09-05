import Foundation

// Shared ordering for the subscribed-shows list (#438), applied on both LibraryView and
// SubscriptionsView so one synced setting (UserSettings.subscriptionSortOrder) drives both.
// Mirrors src/Kuulla.Web/Services/SubscriptionSorting.cs.
func sortedSubscriptions(_ subscriptions: [Subscription], by order: SubscriptionSortOrder) -> [Subscription] {
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
    case .title, .manual:
        // Manual ordering ships in a follow-up (#438 PR 2); until then it renders as Title.
        return subscriptions.sorted {
            $0.showTitle.localizedCaseInsensitiveCompare($1.showTitle) == .orderedAscending
        }
    }
}
