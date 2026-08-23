import Foundation

// Device-local settings that never round-trip through the API — per
// docs/data-usage-network-settings.md's "Device-local, not synced" decision, a user's phone
// being on Wi-Fi tells you nothing about whether their laptop is, so these live in UserDefaults
// rather than UserSettings/ShowSettings. SettingsView binds this key directly via @AppStorage;
// this enum exists so non-View code (DownloadManager) reads the same key without duplicating it.
enum LocalSettings {
    static let wifiOnlyDownloadsKey = "wifiOnlyDownloads"

    // Default true: an unattended auto-download silently burning cellular data is a worse
    // surprise than a download that waits for Wi-Fi, per data-usage-network-settings.md.
    static var wifiOnlyDownloads: Bool {
        UserDefaults.standard.object(forKey: wifiOnlyDownloadsKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: wifiOnlyDownloadsKey)
    }
}
