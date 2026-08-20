import Foundation

// Pure grouping helper backing LibraryView's per-show unplayed badges — no unplayed-count concept
// exists on the API or the Web client either; both compute it client-side from the new-episodes
// endpoint's flat episode list, grouped by showId.
enum UnplayedCounts {
    // Mirrors SubscriptionService.NewEpisodesPerShow on the API — the new-episodes endpoint this
    // is computed from caps how many episodes it returns per show, so a count sitting at this cap
    // means "at least this many," not necessarily exact.
    static let newEpisodesPerShowCap = 10

    // Per-show unplayed count, plus whether the raw (pre-filter) item count for that show hit the
    // API's page cap — if so, the true unplayed count may be higher than what was fetched, so
    // callers should render "cap+" rather than the filtered count even though it's under the cap.
    struct Count {
        let unplayed: Int
        let hitCap: Bool
    }

    // Excludes autoPlayed episodes — they're already marked played by the unlistened-episode-limit
    // enforcement job, so they shouldn't count toward an "unplayed" badge (mirrors
    // EpisodeStateClient.GetUnplayedCountsByShowAsync on Web).
    static func compute(from newEpisodes: [NewEpisode]) -> [String: Count] {
        var unplayed: [String: Int] = [:]
        var raw: [String: Int] = [:]
        for newEpisode in newEpisodes {
            let showId = newEpisode.episode.showId
            raw[showId, default: 0] += 1
            if !newEpisode.autoPlayed {
                unplayed[showId, default: 0] += 1
            }
        }
        return unplayed.reduce(into: [:]) { counts, entry in
            let (showId, unplayedCount) = entry
            counts[showId] = Count(unplayed: unplayedCount, hitCap: (raw[showId] ?? 0) >= newEpisodesPerShowCap)
        }
    }
}
