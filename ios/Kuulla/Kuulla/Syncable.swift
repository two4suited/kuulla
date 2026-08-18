import Foundation
import SwiftData

// A SwiftData model that can be reconciled against a server collection via the last-write-wins
// protocol in docs/sync-conventions.md. `id` is the domain identifier shared with the server
// (e.g. an episode id) — distinct from SwiftData's own `persistentModelID`, which is local-store
// only and never sent over the wire.
protocol Syncable: PersistentModel {
    var id: String { get }
    var updatedAt: Date { get set }
    // Set on every local write; cleared once SyncEngine has pushed the record and the server has
    // acknowledged it (accepted or superseded — either way the server is now authoritative).
    var isDirty: Bool { get set }
}
