import Foundation
import SwiftData

// One row per synced domain (e.g. "episodes"), tracking where local state and the server's
// collection last agreed. See docs/sync-conventions.md for the reconciliation protocol this
// drives, and SyncEngine for how it's used.
@Model
final class SyncCursor {
    @Attribute(.unique) var domain: String
    var lastSyncedAt: Date
    var localHash: String
    var deviceId: String

    init(domain: String, deviceId: String, lastSyncedAt: Date = .distantPast, localHash: String = "") {
        self.domain = domain
        self.deviceId = deviceId
        self.lastSyncedAt = lastSyncedAt
        self.localHash = localHash
    }
}
