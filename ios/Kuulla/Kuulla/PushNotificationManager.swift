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
        try? await deviceTokenClient.register(deviceId: DeviceIdentity.current, apnsToken: apnsToken)
    }

    // Called on foreground (scenePhase .active) — catches the user revoking notification
    // permission in Settings, which fires no in-app callback of its own.
    func syncAuthorizationStatus() async {
        let status = await authorizing.currentAuthorizationStatus()
        if status == .denied {
            try? await deviceTokenClient.unregister(deviceId: DeviceIdentity.current)
        }
    }

    // Called on explicit sign-out — the device shouldn't keep receiving pushes for an account
    // it's no longer signed into.
    func unregisterCurrentDevice() async {
        try? await deviceTokenClient.unregister(deviceId: DeviceIdentity.current)
    }
}
