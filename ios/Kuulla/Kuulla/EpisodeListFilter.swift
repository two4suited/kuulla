import Foundation

// Filter/sort chips for ShowDetailView. Client-side only — the episodes endpoint supports
// date-ordered continuation paging, not server-side filter/sort, so these apply over whatever
// pages have been fetched so far (mirrors the Web implementation). No `downloaded` case: there's
// no download/offline feature anywhere in the app, so that chip is a disabled placeholder.
enum EpisodeFilter: CaseIterable {
    case all
    case unfinished
    case unplayed
    case inProgress

    var label: String {
        switch self {
        case .all: "All"
        case .unfinished: "Unfinished"
        case .unplayed: "Unplayed"
        case .inProgress: "In Progress"
        }
    }

    func matches(_ status: EpisodeStatus) -> Bool {
        switch self {
        case .all:
            true
        case .unfinished:
            // Default tab: everything the listener hasn't finished — genuinely-untouched plus
            // partially-played. Auto-played episodes are excluded (they carry their own Restore
            // affordance). Mirrors ShowDetail.razor's EpisodeFilter.Unfinished on Web.
            status == .new || status == .inProgress
        case .unplayed:
            // Auto-played episodes show their own "Auto-marked Played" badge with a Restore
            // action, so they shouldn't also clutter the Unplayed tab (mirrors ShowDetail.razor's
            // IsUnplayed on Web). Only genuinely-untouched episodes count as unplayed here.
            status == .new
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
        sort: EpisodeSortOrder,
        archived: Set<String> = []
    ) -> [Episode] {
        // Archived episodes are hidden from every filter tab, not just Unplayed — auto-archiving
        // (#187) is meant to declutter the active list entirely (mirrors ShowDetail.razor's
        // IsArchived filtering on Web).
        let filtered = episodes.filter { !archived.contains($0.id) && filter.matches(statuses[$0.id] ?? .new) }
        return sort == .oldestFirst ? filtered.reversed() : filtered
    }
}
