import Foundation

// Device-local settings that never round-trip through the API — per
// docs/data-usage-network-settings.md's "Device-local, not synced" decision, a user's phone
// being on Wi-Fi tells you nothing about whether their laptop is, so these live in UserDefaults
// rather than UserSettings/ShowSettings. SettingsView binds these keys directly via @AppStorage;
// this enum exists so non-View code (DownloadManager, AudioPlayer) reads the same keys without
// duplicating them.
enum LocalSettings {
    static let wifiOnlyDownloadsKey = "wifiOnlyDownloads"
    static let wifiOnlyStreamingKey = "wifiOnlyStreaming"

    // Default true: an unattended auto-download silently burning cellular data is a worse
    // surprise than a download that waits for Wi-Fi, per data-usage-network-settings.md.
    static var wifiOnlyDownloads: Bool {
        UserDefaults.standard.object(forKey: wifiOnlyDownloadsKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: wifiOnlyDownloadsKey)
    }

    // Default false: restricting streaming to Wi-Fi is a much bigger behavior change than
    // restricting downloads — playback simply refuses to start on cellular — so it's opt-in,
    // unlike wifiOnlyDownloads above (per data-usage-network-settings.md).
    static var wifiOnlyStreaming: Bool {
        UserDefaults.standard.bool(forKey: wifiOnlyStreamingKey)
    }
}
