import Foundation
import SwiftData

// Local mirror of the API's UserSettings (src/Kuulla.Api/Models/UserSettings.cs), the sync
// domain for #43. Unlike EpisodeStateRecord/PlaylistRecord there's exactly one of these per
// signed-in device — matching the server's "a user has exactly one UserSettings document"
// invariant — so `id` is a fixed constant rather than a per-record identifier.
@Model
final class UserSettingsRecord: Syncable {
    static let localId = "user-settings"

    @Attribute(.unique) var id: String
    var unlistenedEpisodeCount: UnlistenedEpisodeCount
    var autoArchiveRule: AutoArchiveRule
    var autoSkipIntroSeconds: Int
    var autoSkipOutroSeconds: Int
    var playbackSpeed: Float
    var autoDeleteRule: AutoDeleteRule
    var autoDeleteAfterDays: Int
    var autoDownloadNewEpisodes: Bool
    var version: Int
    var updatedAt: Date
    var isDirty: Bool

    init(from settings: UserSettings, isDirty: Bool = false) {
        id = Self.localId
        unlistenedEpisodeCount = settings.unlistenedEpisodeCount
        autoArchiveRule = settings.autoArchiveRule
        autoSkipIntroSeconds = settings.autoSkipIntroSeconds
        autoSkipOutroSeconds = settings.autoSkipOutroSeconds
        playbackSpeed = settings.playbackSpeed
        autoDeleteRule = settings.autoDeleteRule
        autoDeleteAfterDays = settings.autoDeleteAfterDays
        autoDownloadNewEpisodes = settings.autoDownloadNewEpisodes
        version = settings.version
        updatedAt = settings.updatedAt
        self.isDirty = isDirty
    }

    // Overwrites every field from `settings` — used both to mirror a just-accepted local write
    // (isDirty: false) and to apply an incoming server change during reconciliation.
    func apply(_ settings: UserSettings, isDirty: Bool = false) {
        unlistenedEpisodeCount = settings.unlistenedEpisodeCount
        autoArchiveRule = settings.autoArchiveRule
        autoSkipIntroSeconds = settings.autoSkipIntroSeconds
        autoSkipOutroSeconds = settings.autoSkipOutroSeconds
        playbackSpeed = settings.playbackSpeed
        autoDeleteRule = settings.autoDeleteRule
        autoDeleteAfterDays = settings.autoDeleteAfterDays
        autoDownloadNewEpisodes = settings.autoDownloadNewEpisodes
        version = settings.version
        updatedAt = settings.updatedAt
        self.isDirty = isDirty
    }

    // userId is never read off this local mirror (SettingsView doesn't use it, and the local
    // store is implicitly scoped to whichever single user is signed in on this device — the
    // same convention EpisodeStateRecord/PlaylistRecord already follow), so it's left blank
    // rather than threading it through just to round-trip a value nothing consumes.
    var asUserSettings: UserSettings {
        UserSettings(
            userId: "", unlistenedEpisodeCount: unlistenedEpisodeCount, version: version, autoArchiveRule: autoArchiveRule,
            autoSkipIntroSeconds: autoSkipIntroSeconds, autoSkipOutroSeconds: autoSkipOutroSeconds, playbackSpeed: playbackSpeed,
            autoDeleteRule: autoDeleteRule, autoDeleteAfterDays: autoDeleteAfterDays, autoDownloadNewEpisodes: autoDownloadNewEpisodes,
            updatedAt: updatedAt)
    }
}
