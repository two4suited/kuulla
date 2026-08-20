import Foundation

// Filter/sort chips for ShowDetailView. Client-side only — the episodes endpoint supports
// date-ordered continuation paging, not server-side filter/sort, so these apply over whatever
// pages have been fetched so far (mirrors the Web implementation). No `downloaded` case: there's
// no download/offline feature anywhere in the app, so that chip is a disabled placeholder.
enum EpisodeFilter: CaseIterable {
    case all
    case unplayed
    case inProgress

    var label: String {
        switch self {
        case .all: "All"
        case .unplayed: "Unplayed"
        case .inProgress: "In Progress"
        }
    }

    func matches(_ status: EpisodeStatus) -> Bool {
        switch self {
        case .all:
            true
        case .unplayed:
            // Mirrors the Web filter's "unseen" rule: still unplayed if auto-played, since that's
            // a system action rather than the user actually finishing the episode (#98/#99).
            status == .new || status == .autoPlayed
        case .inProgress:
            status == .inProgress
        }
    }
}

enum EpisodeSortOrder: CaseIterable {
    case newestFirst
    case oldestFirst

    var label: String {
        switch self {
        case .newestFirst: "Newest first"
        case .oldestFirst: "Oldest first"
        }
    }
}

enum EpisodeListFilter {
    static func apply(
        episodes: [Episode],
        statuses: [String: EpisodeStatus],
        filter: EpisodeFilter,
        sort: EpisodeSortOrder
    ) -> [Episode] {
        let filtered = episodes.filter { filter.matches(statuses[$0.id] ?? .new) }
        return sort == .oldestFirst ? filtered.reversed() : filtered
    }
}
