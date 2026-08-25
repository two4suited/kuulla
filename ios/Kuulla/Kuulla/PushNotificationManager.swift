import Foundation
import Observation
import UIKit
import UserNotifications

// Thin wrapper around UNUserNotificationCenter, narrowed to what PushNotificationManager needs
// and returning a plain UNAuthorizationStatus rather than the opaque UNNotificationSettings —
// UNNotificationSettings has no public initializer, so a protocol returning it directly couldn't
// be mocked in tests. Mirrors DownloadManager's NetworkPathObserving seam for the same reason.
protocol NotificationAuthorizing {
    func requestAuthorization() async throws -> Bool
    func currentAuthorizationStatus() async -> UNAuthorizationStatus
}

struct SystemNotificationAuthorizing: NotificationAuthorizing {
    func requestAuthorization() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
    }

    func currentAuthorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
}

// Registers this device for remote notifications (with the API's device-token endpoint) once a
// user signs in, and keeps that registration in sync with the OS-level permission — including
// unregistering if the user later revokes notification permission in Settings, which fires no
// in-app callback of its own and is a separate event from an explicit sign-out (#217).
@Observable
final class PushNotificationManager {
    static let shared = PushNotificationManager()

    private let deviceTokenClient: DeviceTokenClient
    private let authorizing: NotificationAuthorizing

    // Bumped by unregisterCurrentDevice() (sign-out). handleDeviceToken() is launched from an
    // unstructured Task in AppDelegate's didRegisterForRemoteNotificationsWithDeviceToken — APNs
    // can deliver that callback (and its register() network call) after a sign-out's unregister
    // DELETE has already completed, which would otherwise silently recreate the device token
    // record for an account the user just signed out of. Mirrors AuthManager's authActionEpoch,
    // which solves the analogous restorePreviousSignIn-vs-explicit-sign-out race the same way.
    // Internal (not private) so PushNotificationManagerTests can deterministically simulate the
    // race via @testable import rather than depending on real Task scheduling order.
    var registrationEpoch = 0

    init(deviceTokenClient: DeviceTokenClient = DeviceTokenClient(), authorizing: NotificationAuthorizing = SystemNotificationAuthorizing()) {
        self.deviceTokenClient = deviceTokenClient
        self.authorizing = authorizing
    }

    // Called once sign-in succeeds. Requesting authorization when it's already been granted or
    // denied is a no-op on iOS (the system prompt only ever appears once), so this is safe to
    // call on every sign-in rather than needing a "have we asked before" flag of our own.
    func requestAuthorizationAndRegister() async {
        do {
            let granted = try await authorizing.requestAuthorization()
            guard granted else { return }
            await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }
        } catch {
            // Best-effort — a permission-request failure shouldn't block sign-in.
        }
    }

    // Called from AppDelegate.application(_:didRegisterForRemoteNotificationsWithDeviceToken:)
    // once APNs actually hands back a token.
    func handleDeviceToken(_ apnsToken: String) async {
        let epochAtStart = registrationEpoch
        try? await deviceTokenClient.register(deviceId: DeviceIdentity.current, apnsToken: apnsToken)
        if registrationEpoch != epochAtStart {
            // Sign-out happened while this registration was in flight — undo it immediately
            // rather than leaving the (now signed-out) device registered to that account.
            try? await deviceTokenClient.unregister(deviceId: DeviceIdentity.current)
        }
    }

    // Called on cold launch (with a restored sign-in) and on every foreground (scenePhase
    // .active). Re-registering when already authorized is deliberate, not just a denial check —
    // requestAuthorizationAndRegister() only ever runs right after an explicit sign-in, so a
    // relaunch with a restored sign-in (or Apple reissuing this device's token) would otherwise
    // never re-request a token; calling registerForRemoteNotifications() again is safe/cheap and
    // never re-prompts the user (only .notDetermined does that, via requestAuthorizationAndRegister).
    func syncAuthorizationStatus() async {
        switch await authorizing.currentAuthorizationStatus() {
        case .authorized, .provisional, .ephemeral:
            await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }
        case .denied:
            // Catches the user revoking notification permission in Settings, which fires no
            // in-app callback of its own.
            try? await deviceTokenClient.unregister(deviceId: DeviceIdentity.current)
        case .notDetermined:
            break
        @unknown default:
            break
        }
    }

    // Called on explicit sign-out — the device shouldn't keep receiving pushes for an account
    // it's no longer signed into.
    func unregisterCurrentDevice() async {
        registrationEpoch += 1
        try? await deviceTokenClient.unregister(deviceId: DeviceIdentity.current)
    }
}
