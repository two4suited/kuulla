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

    static let lifetimeSilenceTimeSavedSecondsKey = "lifetimeSilenceTimeSavedSeconds"

    // Lifetime, on-device running total of real-world seconds saved by silence-trimming (#680,
    // Overcast's "time saved" framing) — accumulates whenever trimSilence OR smartSpeed is on,
    // since both drive SmartSpeedProcessor.silenceTrimEnabled. Device-local like the settings
    // above: this is a per-device listening stat, not a user preference that should round-trip
    // through the API and get averaged/overwritten across a person's other devices — each
    // device's own silence-trim activity only ever happens on that device, so there's nothing to
    // reconcile the way UserSettings' synced fields do.
    static var lifetimeSilenceTimeSavedSeconds: Double {
        get { UserDefaults.standard.double(forKey: lifetimeSilenceTimeSavedSecondsKey) }
        set { UserDefaults.standard.set(newValue, forKey: lifetimeSilenceTimeSavedSecondsKey) }
    }

    // Adds to the running total rather than replacing it — the read-modify-write is safe today
    // because AudioPlayer's only call site dispatches onto DispatchQueue.main.async (the same
    // place onSilenceStateChanged is already handled), never calling this concurrently. That's an
    // ordering convention at the call site, not something the compiler enforces here — a future
    // second caller must keep dispatching to main too, or this needs real synchronization.
    static func addSilenceTimeSaved(_ seconds: TimeInterval) {
        guard seconds > 0 else { return }
        lifetimeSilenceTimeSavedSeconds += seconds
    }

    static let appIconBadgeModeKey = "appIconBadgeMode"
    static let appIconBadgePlaylistIdKey = "appIconBadgePlaylistId"

    // SettingsView binds these same keys via @AppStorage directly; this pair exists so
    // non-View code (AppIconBadge) reads them without duplicating the keys, mirroring this
    // enum's own reason for existing.
    static var appIconBadgeMode: AppIconBadgeMode {
        UserDefaults.standard.string(forKey: appIconBadgeModeKey).flatMap(AppIconBadgeMode.init(rawValue:)) ?? .off
    }

    static var appIconBadgePlaylistId: String? {
        UserDefaults.standard.string(forKey: appIconBadgePlaylistIdKey).flatMap { $0.isEmpty ? nil : $0 }
    }
}

// What the Home Screen icon badge counts, configurable in Settings. Device-local like the rest of
// LocalSettings — the icon badge itself is a per-device OS surface, so there's nothing to sync.
enum AppIconBadgeMode: String, CaseIterable, Identifiable {
    case off
    case unplayedEpisodes
    case playlist

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: "Off"
        case .unplayedEpisodes: "Unplayed Episodes"
        case .playlist: "A Playlist"
        }
    }
}
