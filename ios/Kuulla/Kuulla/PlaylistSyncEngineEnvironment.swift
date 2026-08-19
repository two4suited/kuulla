import SwiftUI

// Mirrors EpisodeSyncEngineEnvironment.swift for the playlists domain's own SyncEngine instance.
private struct PlaylistSyncEngineKey: EnvironmentKey {
    static let defaultValue: SyncEngine<PlaylistSyncAdapter>? = nil
}

extension EnvironmentValues {
    var playlistSyncEngine: SyncEngine<PlaylistSyncAdapter>? {
        get { self[PlaylistSyncEngineKey.self] }
        set { self[PlaylistSyncEngineKey.self] = newValue }
    }
}
