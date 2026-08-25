import CarPlay
import GoogleSignIn
import SwiftData
import SwiftUI
import UserNotifications

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
                        // Independent domains with no data dependency between them — run
                        // concurrently so cold-start latency is the slowest one, not their sum,
                        // matching the scenePhase .active handler below.
                        async let episodes: Void = episodeSyncEngine.syncNow()
                        async let playlists: Void = playlistSyncEngine.syncNow()
                        async let settings: Void = settingsSyncEngine.syncNow()
                        // Catches notification permission having been revoked in Settings since
                        // this device last registered (#217) — not part of the concurrent group
                        // above since it's unrelated to sync and shouldn't gate cold-start on it.
                        async let notifications: Void = PushNotificationManager.shared.syncAuthorizationStatus()
                        _ = await (episodes, playlists, settings, notifications)
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
                    Task { await PushNotificationManager.shared.syncAuthorizationStatus() }
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
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Must be set before the app can receive any notification delegate callback — including
        // one delivered from a cold launch triggered by tapping a notification (#218).
        UNUserNotificationCenter.current().delegate = self
        return true
    }

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

    // The only way to receive APNs' actual device token — SwiftUI's App protocol has no hook for
    // this delegate callback either, same reason handleEventsForBackgroundURLSession above needs
    // this adaptor (#217).
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        Task { await PushNotificationManager.shared.handleDeviceToken(token) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Best-effort — nothing actionable to do beyond not registering a device token.
    }

    // Routes the CarPlay template scene to CarPlaySceneDelegate; the default (phone/pad) scene
    // role falls through to SwiftUI's own scene delegate since no delegate class is specified for
    // it in Info.plist's UIApplicationSceneManifest.
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        if connectingSceneSession.role == .carTemplateApplication {
            let configuration = UISceneConfiguration(name: "CarPlay Configuration", sessionRole: connectingSceneSession.role)
            configuration.delegateClass = CarPlaySceneDelegate.self
            return configuration
        }
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    // Without implementing this, a push arriving while the app is in the foreground is delivered
    // silently — no banner, no sound — which is UNUserNotificationCenterDelegate's default when
    // no delegate (or a delegate that doesn't implement this method) is set (#218).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    // Fires when the user taps a notification (whether the app was foregrounded, backgrounded,
    // or not running at all) — the single, unified hook for "the user wants to go to what this
    // notification was about" (#218).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let route = PushNotificationRouting.route(from: response.notification.request.content.userInfo) else {
            return
        }
        DeepLinkRouter.shared.pendingRoute = route
    }
}
