import SwiftUI

// KuullaApp owns the single episodeSyncEngine instance (it shares the app's ModelContainer, built
// once in KuullaApp.init); this makes it reachable from views without threading it through every
// tab's init chain. Reads of local EpisodeStateRecords still go through the environment-provided
// modelContext (SwiftData's own .modelContainer(...) injection) — only writes need this engine,
// per SyncEngine.write's own doc comment.
private struct EpisodeSyncEngineKey: EnvironmentKey {
    static let defaultValue: SyncEngine<EpisodeSyncAdapter>? = nil
}

extension EnvironmentValues {
    var episodeSyncEngine: SyncEngine<EpisodeSyncAdapter>? {
        get { self[EpisodeSyncEngineKey.self] }
        set { self[EpisodeSyncEngineKey.self] = newValue }
    }
}
