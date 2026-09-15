import Foundation

// Change signal for CatalogCache's snapshot blobs (unplayedCounts / inProgressShowIds). Bumped by
// CatalogCache.recordEpisodeStateChange/removeShowFromSnapshot whenever they actually patch the
// snapshot, so Subscriptions/Library can react while already on screen instead of only re-reading
// on .onAppear or a full catalogRefresh (#772).
//
// A plain shared singleton, not routed through the environment — CatalogCache itself is a static
// enum with no DI story, called from SwiftUI view bodies and from PlaybackQueue/CarPlaySceneDelegate
// (both @MainActor). Every caller is already on the main actor, the same assumption CatalogCache's
// own writes rely on, so this isn't actor-isolated either.
@Observable
final class CatalogCacheSignal {
    static let shared = CatalogCacheSignal()
    private init() {}

    private(set) var version = 0

    func bump() {
        version += 1
    }
}
