import Foundation
import SwiftData

// Local mirror of the API's EpisodeState (src/Kuulla.Api/Models/EpisodeState.cs) — the first
// consumer of SyncEngine/Syncable. `id` is the episode id, matching the server's convention of
// using it as the document id within a user's partition.
@Model
final class EpisodeStateRecord: Syncable {
    @Attribute(.unique) var id: String
    var showId: String
    var positionSeconds: Int
    var completed: Bool
    var updatedAt: Date
    var isDirty: Bool

    init(
        id: String,
        showId: String,
        positionSeconds: Int,
        completed: Bool,
        updatedAt: Date,
        isDirty: Bool = false
    ) {
        self.id = id
        self.showId = showId
        self.positionSeconds = positionSeconds
        self.completed = completed
        self.updatedAt = updatedAt
        self.isDirty = isDirty
    }
}
