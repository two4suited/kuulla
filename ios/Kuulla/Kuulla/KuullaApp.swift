import GoogleSignIn
import SwiftData
import SwiftUI

@main
struct KuullaApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    let modelContainer: ModelContainer
    let episodeSyncEngine: SyncEngine<EpisodeSyncAdapter>
    let playlistSyncEngine: SyncEngine<PlaylistSyncAdapter>
    let settingsSyncEngine: SyncEngine<SettingsSyncAdapter>

    init() {
        let container = try! ModelContainer(
            for: SyncCursor.self, EpisodeStateRecord.self, PlaylistRecord.self, DownloadedEpisodeRecord.self,
            UserSettingsRecord.self
        )
        modelContainer = container
        let episodeEngine = SyncEngine(modelContainer: container, adapter: EpisodeSyncAdapter())
        episodeSyncEngine = episodeEngine
        let playlistEngine = SyncEngine(modelContainer: container, adapter: PlaylistSyncAdapter())
        playlistSyncEngine = playlistEngine
        let settingsEngine = SyncEngine(modelContainer: container, adapter: SettingsSyncAdapter())
        settingsSyncEngine = settingsEngine
        // Must happen before the app finishes launching (BGTaskScheduler's requirement) — App
        // init runs before the first scene appears, so this is the earliest SwiftUI hook for it.
        episodeEngine.registerBackgroundTask()
        playlistEngine.registerBackgroundTask()
        settingsEngine.registerBackgroundTask()
        DownloadManager.shared.configure(modelContainer: container)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.episodeSyncEngine, episodeSyncEngine)
                .environment(\.playlistSyncEngine, playlistSyncEngine)
                .environment(\.settingsSyncEngine, settingsSyncEngine)
                .task {
                    await AuthManager.shared.restorePreviousSignIn()
                    if AuthManager.shared.isSignedIn {
                        await episodeSyncEngine.syncNow()
                        await playlistSyncEngine.syncNow()
                        await settingsSyncEngine.syncNow()
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
                    Task { await playlistSyncEngine.syncNow() }
                    Task { await settingsSyncEngine.syncNow() }
                }
            case .background:
                if AuthManager.shared.isSignedIn {
                    episodeSyncEngine.scheduleBackgroundRefresh()
                    playlistSyncEngine.scheduleBackgroundRefresh()
                    settingsSyncEngine.scheduleBackgroundRefresh()
                }
            case .inactive:
                break
            @unknown default:
                break
            }
        }
    }
}

// Reconnects DownloadManager's background URLSession when the system relaunches the app to
// deliver its events (a download finishing while the app was suspended/terminated) — SwiftUI's
// App protocol has no hook for this delegate callback, so a UIApplicationDelegate adaptor is the
// only way to receive it.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == DownloadManager.sessionIdentifier else {
            completionHandler()
            return
        }
        DownloadManager.shared.setBackgroundCompletionHandler(completionHandler)
    }
}
