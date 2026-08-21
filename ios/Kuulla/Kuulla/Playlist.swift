import Foundation
import SwiftData

// Local mirror of the API's Playlist (src/Kuulla.Api/Models/Playlist.cs), conforming to
// Syncable per the EpisodeStateRecord precedent. `id` matches the server-assigned playlist id.
@Model
final class PlaylistRecord: Syncable {
    @Attribute(.unique) var id: String
    var name: String
    var type: PlaylistType
    // Embedded rather than a separate SwiftData relationship, matching the server's embedded
    // PlaylistItem list — items are always read/written with their parent playlist.
    var items: [PlaylistItemRecord]
    var createdAt: Date
    var updatedAt: Date
    var isDirty: Bool
    // Present only when type == .dynamic. Stored inline like `items`, matching the server's
    // embedded DynamicPlaylistConfig field on Playlist.
    var dynamicConfig: DynamicPlaylistConfigRecord?

    init(
        id: String,
        name: String,
        type: PlaylistType,
        items: [PlaylistItemRecord] = [],
        createdAt: Date,
        updatedAt: Date,
        isDirty: Bool = false,
        dynamicConfig: DynamicPlaylistConfigRecord? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.items = items
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isDirty = isDirty
        self.dynamicConfig = dynamicConfig
    }
}

// Local mirror of the API's PlaylistItem. Not itself a @Model — it's embedded on PlaylistRecord
// exactly as PlaylistItem is embedded on the server's Playlist document, so it's a plain Codable
// value type stored inline rather than a separate SwiftData entity.
struct PlaylistItemRecord: Codable {
    var episodeId: String
    var showId: String
    var addedAt: Date
    // Lexicographically sortable rank string (LexoRank-style), not an integer index — see
    // Kuulla.Api.Models.PlaylistItem for why (concurrent last-write-wins reorder/insert safety).
    var order: String
}

// Mirrors the API's Kuulla.Api.Models.PlaylistType enum, including its raw values, since the
// wire format is a plain integer (see UnlistenedEpisodeCount for the same convention).
enum PlaylistType: Int, Codable {
    case manual = 0
    case dynamic = 1
}

// Local mirror of the API's Kuulla.Api.Models.DynamicPlaylistConfig. Not a @Model for the same
// reason as PlaylistItemRecord — it's embedded on PlaylistRecord, not a standalone entity.
struct DynamicPlaylistConfigRecord: Codable {
    var showIds: [String]
    // Nil means unlimited — mirrors the server's nullable Kuulla.Api.Models.DynamicPlaylistConfig.MaxEpisodes.
    var maxEpisodes: Int?
    var priorityList: [String]
}
