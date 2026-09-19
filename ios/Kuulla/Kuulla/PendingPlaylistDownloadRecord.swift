import Foundation
import SwiftData

// Device-local retry intent for an auto-download whose episode metadata was not available when
// the playlist item arrived. Playlist sync retries these records after every successful round.
@Model
final class PendingPlaylistDownloadRecord {
    @Attribute(.unique) var id: String
    var showId: String
    var createdAt: Date

    init(id: String, showId: String, createdAt: Date = .now) {
        self.id = id
        self.showId = showId
        self.createdAt = createdAt
    }
}
