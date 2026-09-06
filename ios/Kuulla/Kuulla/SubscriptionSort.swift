import Foundation

// Shared ordering for the subscribed-shows list (#438), applied on both LibraryView and
// SubscriptionsView so one synced setting (UserSettings.subscriptionSortOrder) drives both.
// Mirrors src/Kuulla.Web/Services/SubscriptionSorting.cs.
// activeShowIds is the set of subscribed show ids with at least one unplayed or in-progress
// episode — the shows the user is NOT caught up on. It's nil until the caller has loaded
// episode state; while nil, neither the hide filter nor the latest-episode sink applies. When
// hideCaughtUp is set, caught-up shows are dropped entirely — except under .manual, a
// deliberate hand-curated arrangement that always shows every subscribed show.
func sortedSubscriptions(
    _ subscriptions: [Subscription],
    by order: SubscriptionSortOrder,
    manualOrder: [String] = [],
    activeShowIds: Set<String>? = nil,
    hideCaughtUp: Bool = false
) -> [Subscription] {
    var items = subscriptions
    if let activeShowIds, hideCaughtUp, order != .manual {
        items = items.filter { activeShowIds.contains($0.showId) }
    }

    switch order {
    case .latestEpisode:
        // Caught-up shows (not in activeShowIds) sink below active ones — "latest episode" is
        // really "latest unplayed episode", so a show you've finished shouldn't jump the queue
        // on an episode you've already played.
        return items.sorted { lhs, rhs in
            if let activeShowIds {
                let lhsActive = activeShowIds.contains(lhs.showId)
                let rhsActive = activeShowIds.contains(rhs.showId)
                if lhsActive != rhsActive {
                    return lhsActive
                }
            }
            let lhsDate = lhs.latestEpisodePublishedAt ?? .distantPast
            let rhsDate = rhs.latestEpisodePublishedAt ?? .distantPast
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }
            return lhs.showTitle.localizedCaseInsensitiveCompare(rhs.showTitle) == .orderedAscending
        }
    case .recentlyAdded:
        return items.sorted { lhs, rhs in
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
        return items.sorted { lhs, rhs in
            let lhsRank = rank[lhs.showId] ?? Int.max
            let rhsRank = rank[rhs.showId] ?? Int.max
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }
            return lhs.showTitle.localizedCaseInsensitiveCompare(rhs.showTitle) == .orderedAscending
        }
    case .title:
        return items.sorted {
            $0.showTitle.localizedCaseInsensitiveCompare($1.showTitle) == .orderedAscending
        }
    }
}
