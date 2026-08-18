import GoogleSignIn
import SwiftData
import SwiftUI

@main
struct KuullaApp: App {
    @Environment(\.scenePhase) private var scenePhase

    let modelContainer: ModelContainer
    let episodeSyncEngine: SyncEngine<EpisodeSyncAdapter>

    init() {
        let container = try! ModelContainer(for: SyncCursor.self, EpisodeStateRecord.self)
        modelContainer = container
        let engine = SyncEngine(modelContainer: container, adapter: EpisodeSyncAdapter())
        episodeSyncEngine = engine
        // Must happen before the app finishes launching (BGTaskScheduler's requirement) — App
        // init runs before the first scene appears, so this is the earliest SwiftUI hook for it.
        engine.registerBackgroundTask()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .task {
                    await AuthManager.shared.restorePreviousSignIn()
                    if AuthManager.shared.isSignedIn {
                        await episodeSyncEngine.syncNow()
                    }
                }
                .onOpenURL { url in
                    GIDSignIn.sharedInstance.handle(url)
                }
        }
        .modelContainer(modelContainer)
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                if AuthManager.shared.isSignedIn {
                    Task { await episodeSyncEngine.syncNow() }
                }
            case .background:
                if AuthManager.shared.isSignedIn {
                    episodeSyncEngine.scheduleBackgroundRefresh()
                }
            case .inactive:
                break
            @unknown default:
                break
            }
        }
    }
}
