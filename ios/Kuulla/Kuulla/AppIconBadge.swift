import SwiftData
import UserNotifications

// Home Screen icon badge, driven by the configurable AppIconBadgeMode in Settings. Best-effort
// like PlaylistCleanup/DownloadCleanup — a failed read or a denied notification permission just
// leaves the badge showing whatever it last did, rather than surfacing an error to the user for a
// non-critical, glanceable count.
enum AppIconBadge {
    @MainActor
    static func refresh(in context: ModelContext) async {
        let count: Int
        switch LocalSettings.appIconBadgeMode {
        case .off:
            count = 0
        case .unplayedEpisodes:
            // Same source LibraryView's per-show badges use, so the total inherits their known
            // limitation: UnplayedCounts.Count.unplayed is capped per show at
            // UnplayedCounts.newEpisodesPerShowCap (10) — a show with more unplayed back-catalog
            // episodes than that only contributes 10 here, same as its own badge shows "10+"
            // rather than the true count. A single OS badge integer has no way to signal "at
            // least," so this undercounts in that case rather than misrepresenting a hard number.
            count = CatalogCache.unplayedCounts(in: context).values.reduce(0) { $0 + $1.unplayed }
        case .playlist:
            count = playlistItemCount(in: context)
        }
        try? await UNUserNotificationCenter.current().setBadgeCount(count)
    }

    // Reads the locally-synced PlaylistRecord rather than hitting the network — same store
    // PlaylistsView paints its shelf from (Playlist.swift's PlaylistSummary), so this is only ever
    // as fresh as the last playlist sync, matching every other badge in the app (#556).
    private static func playlistItemCount(in context: ModelContext) -> Int {
        guard let playlistId = LocalSettings.appIconBadgePlaylistId else { return 0 }
        let descriptor = FetchDescriptor<PlaylistRecord>(predicate: #Predicate { $0.id == playlistId })
        guard let record = try? context.fetch(descriptor).first, !record.deleted else { return 0 }
        return record.items.count
    }
}
