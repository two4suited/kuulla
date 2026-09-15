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
    let catalogRefreshService: CatalogRefreshService

    init() {
        let container = try! ModelContainer(
            for: SyncCursor.self, EpisodeStateRecord.self, PlaylistRecord.self, DownloadedEpisodeRecord.self,
            UserSettingsRecord.self,
            // Read-through catalog cache (not sync domains) — see CatalogCache.
            SubscriptionRecord.self, ShowRecord.self, CachedEpisodeRecord.self,
            CachedNewEpisodeRecord.self, ShowEpisodePageRecord.self, CatalogCacheState.self
        )
        modelContainer = container
        let episodeEngine = SyncEngine(modelContainer: container, adapter: EpisodeSyncAdapter())
        episodeSyncEngine = episodeEngine
        let playlistEngine = SyncEngine(modelContainer: container, adapter: PlaylistSyncAdapter())
        playlistSyncEngine = playlistEngine
        let settingsEngine = SyncEngine(modelContainer: container, adapter: SettingsSyncAdapter())
        settingsSyncEngine = settingsEngine
        // App.init() runs on the main actor; assumeIsolated lets us build the @MainActor
        // CatalogRefreshService here without hopping.
        catalogRefreshService = MainActor.assumeIsolated {
            CatalogRefreshService(
                modelContainer: container,
                episodeSyncEngine: episodeEngine,
                playlistSyncEngine: playlistEngine,
                settingsSyncEngine: settingsEngine)
        }
        // Must happen before the app finishes launching (BGTaskScheduler's requirement) — App
        // init runs before the first scene appears, so this is the earliest SwiftUI hook for it.
        episodeEngine.registerBackgroundTask()
        playlistEngine.registerBackgroundTask()
        settingsEngine.registerBackgroundTask()
        DownloadManager.shared.configure(modelContainer: container)
        CarPlaySceneDelegate.modelContainer = container
        CarPlaySceneDelegate.episodeSyncEngine = episodeEngine
        CarPlaySceneDelegate.settingsSyncEngine = settingsEngine
        CarPlaySceneDelegate.playlistSyncEngine = playlistEngine
        // Overcast-style playlist auto-advance (#532) — same out-of-SwiftUI wiring as CarPlay,
        // since the queue starts follow-on episodes from AudioPlayer's finish callback.
        PlaybackQueue.modelContainer = container
        PlaybackQueue.episodeSyncEngine = episodeEngine
        // AppDelegate's didReceiveRemoteNotification needs a way to trigger a targeted refresh —
        // same out-of-SwiftUI wiring as CarPlay/PlaybackQueue above.
        AppDelegate.modelContainer = container
        AppDelegate.catalogRefreshService = catalogRefreshService
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                // Signal accent — every Button, Slider, Toggle, ProgressView and
                // selected tab picks this up as Color.accentColor (docs/brand.md).
                .tint(KuullaColor.signal)
                // Signal is dark-first and the iOS app ships dark (docs/brand.md §1).
                // The colour assets still carry a light variant for a future opt-in.
                .preferredColorScheme(.dark)
                .environment(\.episodeSyncEngine, episodeSyncEngine)
                .environment(\.playlistSyncEngine, playlistSyncEngine)
                .environment(\.settingsSyncEngine, settingsSyncEngine)
                .environment(\.catalogRefresh, catalogRefreshService)
                .task {
                    await WatchConnectivitySession.shared.activate()
                    await AuthManager.shared.restorePreviousSignIn()
                    if AuthManager.shared.isSignedIn {
                        // Cold launch is the one automatic full sync (#488): the browsing
                        // catalog (subscriptions/shows/episodes) and the three bidirectional
                        // sync domains all refresh once here. After this, refreshing is manual
                        // — the "Sync Now" button in Settings, or pull-to-refresh on a list —
                        // except for the ~15-min background pull scheduled on .background below.
                        async let catalog: Void = catalogRefreshService.refreshAll()
                        // Catches notification permission having been revoked in Settings since
                        // this device last registered (#217) — kept separate so it doesn't gate
                        // cold-start on the catalog refresh.
                        async let notifications: Void = PushNotificationManager.shared.syncAuthorizationStatus()
                        _ = await (catalog, notifications)
                        await AppIconBadge.refresh(in: modelContainer.mainContext)
                    }
                }
                .onOpenURL { url in
                    GIDSignIn.sharedInstance.handle(url)
                }
                // Separate .task from the one above (rather than folded in): this one runs for
                // the app's entire lifetime watching for the watch to (re)connect, and would
                // otherwise block cold-launch auth restore/sync forever since `for await` never
                // returns on its own (#582).
                .task {
                    for await reachable in await WatchConnectivitySession.shared.reachabilityUpdates
                    where reachable {
                        AudioPlayer.shared.republishNowPlayingToWatch()
                    }
                }
        }
        .modelContainer(modelContainer)
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                if AuthManager.shared.isSignedIn {
                    // No sync on every foreground anymore (#488) — that's what put the app on
                    // the network each time it was opened. Sync is manual now (Settings →
                    // "Sync Now", or pull-to-refresh); cold launch and the scheduled background
                    // refresh still cover the automatic cases.
                    Task { await PushNotificationManager.shared.syncAuthorizationStatus() }
                }
                // Catches changes made on another device (or in another app session) since this
                // one last computed the badge — cheap local-only read, so it's fine on every
                // foreground even though catalog/playlist sync itself isn't (#488 above).
                // Deliberately not gated on isSignedIn like the sync call above: a badge left over
                // from before a sign-out should still clear to zero (everything local reads as
                // empty once signed out), not linger until the next launch.
                Task { await AppIconBadge.refresh(in: modelContainer.mainContext) }
            case .background:
                if AuthManager.shared.isSignedIn {
                    episodeSyncEngine.scheduleBackgroundRefresh()
                    playlistSyncEngine.scheduleBackgroundRefresh()
                    settingsSyncEngine.scheduleBackgroundRefresh()
                }
                Task { await AppIconBadge.refresh(in: modelContainer.mainContext) }
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
    static var modelContainer: ModelContainer?
    static var catalogRefreshService: CatalogRefreshService?

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

    // Fires for a silent (content-available: 1) push, whether the app is foregrounded,
    // backgrounded, or launched from suspended — the OS grants a short background execution
    // window to run the completion handler in. Requires the "remote-notification" background
    // mode (Info.plist), same as the willPresent/didReceive hooks below need their delegate set
    // in didFinishLaunching (#749). Refreshes only the pushed show (not a full sync) to stay
    // inside that window.
    //
    // Implicitly MainActor-isolated (like the rest of this class, via the UIApplicationDelegate
    // conformance) — needed to touch the MainActor-isolated `modelContainer`/`catalogRefreshService`
    // statics and ModelContext below without hopping.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        guard let route = PushNotificationRouting.route(from: userInfo) else { return .noData }
        guard let container = Self.modelContainer, let catalogRefreshService = Self.catalogRefreshService else {
            return .failed
        }
        // Mirrors the isSignedIn gate on every other refresh trigger in this file (cold-launch
        // .task, .background scenePhase) — a push can still arrive after sign-out if the device
        // unregister (best-effort, see PushNotificationManager.unregisterCurrentDevice) hasn't
        // landed server-side yet, and refreshShow's catalog requests would just fail
        // unauthenticated at that point.
        guard AuthManager.shared.isSignedIn else { return .noData }
        // PushNotificationRouting only ever produces .show or .episode (see its doc comment).
        let showId: String
        switch route {
        case .show(let id):
            showId = id
        case .episode(let id, _, _, _):
            showId = id
        default:
            return .noData
        }
        await catalogRefreshService.refreshShow(showId: showId)
        await AppIconBadge.refresh(in: container.mainContext)
        return .newData
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
