import Foundation

// Pure grouping helper backing LibraryView's per-show unplayed badges — no unplayed-count concept
// exists on the API or the Web client either; both compute it client-side from the new-episodes
// endpoint's flat episode list, grouped by showId.
enum UnplayedCounts {
    // Mirrors SubscriptionService.NewEpisodesPerShow on the API — the new-episodes endpoint this
    // is computed from caps how many episodes it returns per show, so a count sitting at this cap
    // means "at least this many," not necessarily exact.
    static let newEpisodesPerShowCap = 10

    static func compute(from showIds: [String]) -> [String: Int] {
        Dictionary(grouping: showIds, by: { $0 }).mapValues(\.count)
    }
}
