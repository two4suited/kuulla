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
    var smartSpeed: Bool
    // Inline default required, same lightweight-migration reason as notificationsEnabled below (#679).
    var voiceBoost: Bool = false
    // Inline default required, same lightweight-migration reason as voiceBoost above (#680).
    var trimSilence: Bool = false
    // Inline default (unlike every other property on this model) is required, not just
    // convenient — SwiftData's lightweight/automatic migration can add a new attribute to an
    // existing on-disk store, but only if it can synthesize a value for already-persisted rows;
    // a non-optional attribute with no default fails migration outright (reproduced locally:
    // "missing attribute values on mandatory destination attribute", a hard crash on launch for
    // any device with a store predating this field, not just a test artifact).
    var notificationsEnabled: Bool = true
    // No inline default needed (unlike notificationsEnabled above) — SwiftData's lightweight
    // migration can synthesize nil for a new *optional* attribute on already-persisted rows
    // without one; the default-required case only applies to non-optional attributes.
    var sleepTimerDefaultDurationMinutes: Int?
    // Inline default required, same rationale as notificationsEnabled above — a non-optional
    // SwiftData attribute with no default fails lightweight migration for any store predating
    // this field. .title matches the API's own default for #438.
    var subscriptionSortOrder: SubscriptionSortOrder = SubscriptionSortOrder.title
    // Inline default required for the same lightweight-migration reason as the fields above.
    // `[String]` persists fine as a SwiftData attribute (stored as a value type). #438 manual sort.
    var subscriptionManualOrder: [String] = [String]()
    // Inline default required for the same lightweight-migration reason as the fields above.
    // #438 follow-up: hide caught-up shows from the Library/Subscriptions list.
    var hideCaughtUpShows: Bool = false
    // Inline default required, same lightweight-migration reason as the fields above. #440.
    var autoAddNewEpisodesToUpNext: Bool = false
    // Inline default required, same reason. .bottom matches the API's default for #440.
    var upNextInsertPosition: UpNextInsertPosition = UpNextInsertPosition.bottom
    // Inline default required, same lightweight-migration reason as the fields above (#568).
    var leadingSwipeActions: [EpisodeSwipeAction] = []
    var trailingSwipeActions: [EpisodeSwipeAction] = [EpisodeSwipeAction.addToPlaylist, EpisodeSwipeAction.markPlayed]
    // Stored as Optional rather than an inline-defaulted non-optional attribute like the fields
    // above (#635): lightweight migration synthesizing nil for a new *optional* attribute is
    // safe (see sleepTimerDefaultDurationMinutes above), but for this enum-backed attribute
    // synthesizing the non-optional inline default on some already-persisted rows fetched back
    // as `Optional<Any>` at the SwiftData/CoreData layer instead of `PlayNextBehavior`, and the
    // generated property getter's implicit cast crashed rather than falling back to the default
    // (#635). The computed property below applies the default in plain Swift instead of relying
    // on SwiftData to synthesize it.
    private var playNextBehaviorRaw: PlayNextBehavior?
    var playNextBehavior: PlayNextBehavior {
        get { playNextBehaviorRaw ?? .nextInList }
        set { playNextBehaviorRaw = newValue }
    }
    var version: Int
    var updatedAt: Date
    var isDirty: Bool

    init(
        unlistenedEpisodeCount: UnlistenedEpisodeCount, autoArchiveRule: AutoArchiveRule,
        autoSkipIntroSeconds: Int, autoSkipOutroSeconds: Int, playbackSpeed: Float,
        autoDeleteRule: AutoDeleteRule, autoDeleteAfterDays: Int, autoDownloadNewEpisodes: Bool,
        smartSpeed: Bool, voiceBoost: Bool, trimSilence: Bool, notificationsEnabled: Bool, sleepTimerDefaultDurationMinutes: Int? = nil,
        subscriptionSortOrder: SubscriptionSortOrder = .title,
        subscriptionManualOrder: [String] = [],
        hideCaughtUpShows: Bool = false,
        autoAddNewEpisodesToUpNext: Bool = false,
        upNextInsertPosition: UpNextInsertPosition = .bottom,
        leadingSwipeActions: [EpisodeSwipeAction] = [],
        trailingSwipeActions: [EpisodeSwipeAction] = [.addToPlaylist, .markPlayed],
        playNextBehavior: PlayNextBehavior = .nextInList,
        version: Int, updatedAt: Date, isDirty: Bool = false
    ) {
        id = Self.localId
        self.unlistenedEpisodeCount = unlistenedEpisodeCount
        self.autoArchiveRule = autoArchiveRule
        self.autoSkipIntroSeconds = autoSkipIntroSeconds
        self.autoSkipOutroSeconds = autoSkipOutroSeconds
        self.playbackSpeed = playbackSpeed
        self.autoDeleteRule = autoDeleteRule
        self.autoDeleteAfterDays = autoDeleteAfterDays
        self.autoDownloadNewEpisodes = autoDownloadNewEpisodes
        self.smartSpeed = smartSpeed
        self.voiceBoost = voiceBoost
        self.trimSilence = trimSilence
        self.notificationsEnabled = notificationsEnabled
        self.sleepTimerDefaultDurationMinutes = sleepTimerDefaultDurationMinutes
        self.subscriptionSortOrder = subscriptionSortOrder
        self.subscriptionManualOrder = subscriptionManualOrder
        self.hideCaughtUpShows = hideCaughtUpShows
        self.autoAddNewEpisodesToUpNext = autoAddNewEpisodesToUpNext
        self.upNextInsertPosition = upNextInsertPosition
        self.leadingSwipeActions = leadingSwipeActions
        self.trailingSwipeActions = trailingSwipeActions
        self.playNextBehaviorRaw = playNextBehavior
        self.version = version
        self.updatedAt = updatedAt
        self.isDirty = isDirty
    }

    convenience init(from settings: UserSettings, isDirty: Bool = false) {
        self.init(
            unlistenedEpisodeCount: settings.unlistenedEpisodeCount, autoArchiveRule: settings.autoArchiveRule,
            autoSkipIntroSeconds: settings.autoSkipIntroSeconds, autoSkipOutroSeconds: settings.autoSkipOutroSeconds,
            playbackSpeed: settings.playbackSpeed, autoDeleteRule: settings.autoDeleteRule,
            autoDeleteAfterDays: settings.autoDeleteAfterDays, autoDownloadNewEpisodes: settings.autoDownloadNewEpisodes,
            smartSpeed: settings.smartSpeed, voiceBoost: settings.voiceBoost, trimSilence: settings.trimSilence,
            notificationsEnabled: settings.notificationsEnabled,
            sleepTimerDefaultDurationMinutes: settings.sleepTimerDefaultDurationMinutes,
            subscriptionSortOrder: settings.subscriptionSortOrder,
            subscriptionManualOrder: settings.subscriptionManualOrder,
            hideCaughtUpShows: settings.hideCaughtUpShows,
            autoAddNewEpisodesToUpNext: settings.autoAddNewEpisodesToUpNext,
            upNextInsertPosition: settings.upNextInsertPosition,
            leadingSwipeActions: settings.leadingSwipeActions,
            trailingSwipeActions: settings.trailingSwipeActions,
            playNextBehavior: settings.playNextBehavior,
            version: settings.version, updatedAt: settings.updatedAt, isDirty: isDirty)
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
        smartSpeed = settings.smartSpeed
        voiceBoost = settings.voiceBoost
        trimSilence = settings.trimSilence
        notificationsEnabled = settings.notificationsEnabled
        sleepTimerDefaultDurationMinutes = settings.sleepTimerDefaultDurationMinutes
        subscriptionSortOrder = settings.subscriptionSortOrder
        subscriptionManualOrder = settings.subscriptionManualOrder
        hideCaughtUpShows = settings.hideCaughtUpShows
        autoAddNewEpisodesToUpNext = settings.autoAddNewEpisodesToUpNext
        upNextInsertPosition = settings.upNextInsertPosition
        leadingSwipeActions = settings.leadingSwipeActions
        trailingSwipeActions = settings.trailingSwipeActions
        playNextBehavior = settings.playNextBehavior
        version = settings.version
        updatedAt = settings.updatedAt
        self.isDirty = isDirty
    }

    // Same as apply(_:isDirty:) but copies from another UserSettingsRecord directly — lets
    // SettingsSyncAdapter.apply go record-to-record without a round trip through UserSettings
    // (and its userId: "" placeholder) just to get from one record's fields to another's.
    func apply(_ other: UserSettingsRecord, isDirty: Bool = false) {
        unlistenedEpisodeCount = other.unlistenedEpisodeCount
        autoArchiveRule = other.autoArchiveRule
        autoSkipIntroSeconds = other.autoSkipIntroSeconds
        autoSkipOutroSeconds = other.autoSkipOutroSeconds
        playbackSpeed = other.playbackSpeed
        autoDeleteRule = other.autoDeleteRule
        autoDeleteAfterDays = other.autoDeleteAfterDays
        autoDownloadNewEpisodes = other.autoDownloadNewEpisodes
        smartSpeed = other.smartSpeed
        voiceBoost = other.voiceBoost
        trimSilence = other.trimSilence
        notificationsEnabled = other.notificationsEnabled
        sleepTimerDefaultDurationMinutes = other.sleepTimerDefaultDurationMinutes
        subscriptionSortOrder = other.subscriptionSortOrder
        subscriptionManualOrder = other.subscriptionManualOrder
        hideCaughtUpShows = other.hideCaughtUpShows
        autoAddNewEpisodesToUpNext = other.autoAddNewEpisodesToUpNext
        upNextInsertPosition = other.upNextInsertPosition
        leadingSwipeActions = other.leadingSwipeActions
        trailingSwipeActions = other.trailingSwipeActions
        playNextBehavior = other.playNextBehavior
        version = other.version
        updatedAt = other.updatedAt
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
            smartSpeed: smartSpeed, voiceBoost: voiceBoost, trimSilence: trimSilence, notificationsEnabled: notificationsEnabled,
            sleepTimerDefaultDurationMinutes: sleepTimerDefaultDurationMinutes,
            subscriptionSortOrder: subscriptionSortOrder,
            subscriptionManualOrder: subscriptionManualOrder,
            hideCaughtUpShows: hideCaughtUpShows,
            autoAddNewEpisodesToUpNext: autoAddNewEpisodesToUpNext,
            upNextInsertPosition: upNextInsertPosition,
            leadingSwipeActions: leadingSwipeActions,
            trailingSwipeActions: trailingSwipeActions,
            playNextBehavior: playNextBehavior,
            updatedAt: updatedAt)
    }
}
