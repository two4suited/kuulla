import Foundation

// Pure grouping helper backing LibraryView's per-show unplayed badges — no unplayed-count concept
// exists on the API or the Web client either; both compute it client-side from the new-episodes
// endpoint's flat episode list, grouped by showId.
enum UnplayedCounts {
    // Mirrors SubscriptionService.NewEpisodesPerShow on the API — the new-episodes endpoint this
    // is computed from caps how many episodes it returns per show, so a count sitting at this cap
    // means "at least this many," not necessarily exact.
    static let newEpisodesPerShowCap = 10

    // Per-show unplayed count, plus whether that count hit the API's page cap — if so, the fetched
    // page may not contain every genuinely-unplayed episode for the show, so callers should render
    // "{unplayed}+" rather than the bare count even though it's exactly at the cap.
    //
    // hitCap is deliberately based on the *filtered* (auto-played-excluded) count, not the raw
    // per-show item count: the unlistened-episode-limit enforcement job (#98/#135) auto-marks every
    // episode beyond a user's limit as played across a show's entire back catalog, not just the
    // page fetched here. So once a show's raw page contains any auto-played episodes, every
    // genuinely-unplayed episode for that show is guaranteed to already be in this page — the raw
    // count hitting the cap carries no extra information in that case. The only case where more
    // unplayed episodes could exist beyond this page is when the whole fetched page is unplayed
    // (nothing to auto-play within it), which is exactly unplayed == raw == cap.
    struct Count {
        let unplayed: Int
        let hitCap: Bool
    }

    // Excludes autoPlayed episodes — they're already marked played by the unlistened-episode-limit
    // enforcement job, so they shouldn't count toward an "unplayed" badge (mirrors
    // EpisodeStateClient.GetUnplayedCountsByShowAsync on Web).
    static func compute(from newEpisodes: [NewEpisode]) -> [String: Count] {
        var unplayed: [String: Int] = [:]
        for newEpisode in newEpisodes where !newEpisode.autoPlayed {
            unplayed[newEpisode.episode.showId, default: 0] += 1
        }
        return unplayed.mapValues { unplayedCount in
            Count(unplayed: unplayedCount, hitCap: unplayedCount >= newEpisodesPerShowCap)
        }
    }

    // Rebuilds the badge map from the flat [showId: unplayedCount] dictionary persisted by the
    // catalog cache — the same shape `compute` produces before it wraps each value in `Count`.
    static func counts(fromUnplayedByShow unplayedByShow: [String: Int]) -> [String: Count] {
        unplayedByShow.mapValues { unplayedCount in
            Count(unplayed: unplayedCount, hitCap: unplayedCount >= newEpisodesPerShowCap)
        }
    }

    // The inverse of `counts(fromUnplayedByShow:)` — flattens the badge map for persistence.
    static func unplayedByShow(from counts: [String: Count]) -> [String: Int] {
        counts.mapValues(\.unplayed)
    }
}
