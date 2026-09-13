import Foundation

struct UserSettings: Codable, Hashable {
    let userId: String
    let unlistenedEpisodeCount: UnlistenedEpisodeCount
    let version: Int
    let autoArchiveRule: AutoArchiveRule
    let autoSkipIntroSeconds: Int
    let autoSkipOutroSeconds: Int
    let playbackSpeed: Float
    let autoDeleteRule: AutoDeleteRule
    let autoDeleteAfterDays: Int
    let autoDownloadNewEpisodes: Bool
    let smartSpeed: Bool
    // Normalizes loudness across episodes (#679) — independent of SmartSpeed's silence-trimming,
    // though SmartSpeed still implies this boost too (see SmartSpeedProcessor).
    let voiceBoost: Bool
    let notificationsEnabled: Bool
    // Nil means the user has never picked a sleep timer duration yet (#208 seeds the picker with
    // its own baked-in default in that case, rather than this being some other sentinel). Unlike
    // every field above, genuinely nullable in storage (Kuulla.Api.Models.UserSettings.cs) — not
    // just "absent from an old response" — so absence-from-JSON and "no default chosen" collapse
    // to the same nil here, same as the API's own decode.
    let sleepTimerDefaultDurationMinutes: Int?
    // How the subscribed-shows list is ordered on Library/Subscriptions (#438). Defaults to
    // .title (see decoder below) when absent — the historical Library default — so an API
    // response that predates this field decodes cleanly.
    let subscriptionSortOrder: SubscriptionSortOrder
    // The user's hand-ordered subscription list for .manual sort (#438) — an ordered array of
    // showId, edited wholesale on every drag. Empty (see decoder) when unused or absent from an
    // older response; consumers treat empty as "no manual order". No-longer-subscribed ids are
    // ignored on read; newly-subscribed shows not yet listed fall to the end by title.
    let subscriptionManualOrder: [String]
    // When true, the Library/Subscriptions shows list hides shows the user is caught up on —
    // nothing unplayed and nothing in progress (#438 follow-up). Defaults to false (see decoder)
    // when absent, same as the API's own CLR-zero default. Even when false, a caught-up show
    // sinks below active ones under .latestEpisode sort — that's client-side ordering only.
    let hideCaughtUpShows: Bool
    // Auto-add new subscription episodes to the "Up Next" playlist (#440). Defaults to false
    // (opt-in) when absent, same as autoDownloadNewEpisodes.
    let autoAddNewEpisodesToUpNext: Bool
    // Which end of the Up Next queue an auto-added episode lands at (#440). Defaults to .bottom
    // (raw 0) when absent, same rationale as subscriptionSortOrder.
    let upNextInsertPosition: UpNextInsertPosition
    // Which quick actions appear on a leading/trailing swipe over an episode-list row (#568).
    // Defaults to the historical trailing-only behavior (Add to Playlist, then Mark as Played)
    // when absent (predates this field) — see decoder below.
    let leadingSwipeActions: [EpisodeSwipeAction]
    let trailingSwipeActions: [EpisodeSwipeAction]
    // What plays when an episode finishes (#629). Defaults to .nextInList (raw 0) when absent —
    // the API's own default and what manual playlists did before the setting existed (#532).
    let playNextBehavior: PlayNextBehavior
    // Server-stamped (docs/sync-conventions.md) — drives last-write-wins for #43's settings
    // sync. .distantPast when absent (see decoder below) so a locally-constructed UserSettings
    // never accidentally wins an LWW comparison against a real server timestamp.
    let updatedAt: Date

    init(
        userId: String, unlistenedEpisodeCount: UnlistenedEpisodeCount, version: Int, autoArchiveRule: AutoArchiveRule,
        autoSkipIntroSeconds: Int = 0, autoSkipOutroSeconds: Int = 0, playbackSpeed: Float = 1.0,
        autoDeleteRule: AutoDeleteRule = .never, autoDeleteAfterDays: Int = 7, autoDownloadNewEpisodes: Bool = false,
        smartSpeed: Bool = false, voiceBoost: Bool = false,
        notificationsEnabled: Bool = true, sleepTimerDefaultDurationMinutes: Int? = nil,
        subscriptionSortOrder: SubscriptionSortOrder = .title,
        subscriptionManualOrder: [String] = [],
        hideCaughtUpShows: Bool = false,
        autoAddNewEpisodesToUpNext: Bool = false,
        upNextInsertPosition: UpNextInsertPosition = .bottom,
        leadingSwipeActions: [EpisodeSwipeAction] = [],
        trailingSwipeActions: [EpisodeSwipeAction] = [.addToPlaylist, .markPlayed],
        playNextBehavior: PlayNextBehavior = .nextInList,
        updatedAt: Date = .distantPast
    ) {
        self.userId = userId
        self.unlistenedEpisodeCount = unlistenedEpisodeCount
        self.version = version
        self.autoArchiveRule = autoArchiveRule
        self.autoSkipIntroSeconds = autoSkipIntroSeconds
        self.autoSkipOutroSeconds = autoSkipOutroSeconds
        self.playbackSpeed = playbackSpeed
        self.autoDeleteRule = autoDeleteRule
        self.autoDeleteAfterDays = autoDeleteAfterDays
        self.autoDownloadNewEpisodes = autoDownloadNewEpisodes
        self.smartSpeed = smartSpeed
        self.voiceBoost = voiceBoost
        self.notificationsEnabled = notificationsEnabled
        self.sleepTimerDefaultDurationMinutes = sleepTimerDefaultDurationMinutes
        self.subscriptionSortOrder = subscriptionSortOrder
        self.subscriptionManualOrder = subscriptionManualOrder
        self.hideCaughtUpShows = hideCaughtUpShows
        self.autoAddNewEpisodesToUpNext = autoAddNewEpisodesToUpNext
        self.upNextInsertPosition = upNextInsertPosition
        self.leadingSwipeActions = leadingSwipeActions
        self.trailingSwipeActions = trailingSwipeActions
        self.playNextBehavior = playNextBehavior
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case userId, unlistenedEpisodeCount, version, autoArchiveRule, autoSkipIntroSeconds, autoSkipOutroSeconds, playbackSpeed
        case autoDeleteRule, autoDeleteAfterDays, autoDownloadNewEpisodes, smartSpeed, voiceBoost, notificationsEnabled
        case sleepTimerDefaultDurationMinutes, subscriptionSortOrder, subscriptionManualOrder, hideCaughtUpShows
        case autoAddNewEpisodesToUpNext, upNextInsertPosition, leadingSwipeActions, trailingSwipeActions
        case playNextBehavior, updatedAt
    }

    // Defaults to .never when absent so a response that predates #187's field addition still
    // decodes cleanly rather than failing entirely (mirrors EpisodeSyncAdapter's DTO precedent).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        userId = try container.decode(String.self, forKey: .userId)
        unlistenedEpisodeCount = try container.decode(UnlistenedEpisodeCount.self, forKey: .unlistenedEpisodeCount)
        version = try container.decode(Int.self, forKey: .version)
        autoArchiveRule = try container.decodeIfPresent(AutoArchiveRule.self, forKey: .autoArchiveRule) ?? .never
        // Default to 0 (off) when absent, same rationale as autoArchiveRule above.
        autoSkipIntroSeconds = try container.decodeIfPresent(Int.self, forKey: .autoSkipIntroSeconds) ?? 0
        autoSkipOutroSeconds = try container.decodeIfPresent(Int.self, forKey: .autoSkipOutroSeconds) ?? 0
        // Default to 1.0 (normal speed) when absent, same rationale as autoArchiveRule above.
        playbackSpeed = try container.decodeIfPresent(Float.self, forKey: .playbackSpeed) ?? 1.0
        // Default to .never/7 when absent (#179), same rationale as autoArchiveRule above.
        autoDeleteRule = try container.decodeIfPresent(AutoDeleteRule.self, forKey: .autoDeleteRule) ?? .never
        autoDeleteAfterDays = try container.decodeIfPresent(Int.self, forKey: .autoDeleteAfterDays) ?? 7
        // Default to false (off) when absent (#268), same rationale as autoArchiveRule above.
        autoDownloadNewEpisodes = try container.decodeIfPresent(Bool.self, forKey: .autoDownloadNewEpisodes) ?? false
        // Default to false (off) when absent (predates #200), same rationale as autoArchiveRule above.
        smartSpeed = try container.decodeIfPresent(Bool.self, forKey: .smartSpeed) ?? false
        // Default to false (off) when absent (predates #679), same rationale as smartSpeed above.
        voiceBoost = try container.decodeIfPresent(Bool.self, forKey: .voiceBoost) ?? false
        // Default to true (on) when absent (predates #211) — matches the API's own opt-out
        // default (UserSettings.cs: notifications are the point of registering a device for
        // push, so absence should mean "on" here, unlike every opt-in field above).
        notificationsEnabled = try container.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? true
        // Absent (predates #205) decodes the same as an explicit null (no default chosen yet) —
        // both mean "nothing to seed the picker with", so there's no separate fallback here.
        sleepTimerDefaultDurationMinutes = try container.decodeIfPresent(Int.self, forKey: .sleepTimerDefaultDurationMinutes)
        // Default to .title when absent (#438) — the historical Library sort — same rationale as
        // autoArchiveRule above.
        subscriptionSortOrder = try container.decodeIfPresent(
            SubscriptionSortOrder.self, forKey: .subscriptionSortOrder) ?? .title
        // Absent (older response) or explicit null both decode to [] — "no manual order".
        subscriptionManualOrder = try container.decodeIfPresent([String].self, forKey: .subscriptionManualOrder) ?? []
        // Default to false when absent (#438 follow-up) — same rationale as autoArchiveRule above.
        hideCaughtUpShows = try container.decodeIfPresent(Bool.self, forKey: .hideCaughtUpShows) ?? false
        // Default to false (off) when absent (#440), same rationale as autoDownloadNewEpisodes above.
        autoAddNewEpisodesToUpNext = try container.decodeIfPresent(Bool.self, forKey: .autoAddNewEpisodesToUpNext) ?? false
        // Default to .bottom when absent (#440), same rationale as subscriptionSortOrder above.
        upNextInsertPosition = try container.decodeIfPresent(
            UpNextInsertPosition.self, forKey: .upNextInsertPosition) ?? .bottom
        // Default to [] / [.addToPlaylist, .markPlayed] when absent (#568) — the historical
        // trailing-swipe-only behavior, same rationale as upNextInsertPosition above.
        leadingSwipeActions = try container.decodeIfPresent(
            [EpisodeSwipeAction].self, forKey: .leadingSwipeActions) ?? []
        trailingSwipeActions = try container.decodeIfPresent(
            [EpisodeSwipeAction].self, forKey: .trailingSwipeActions) ?? [.addToPlaylist, .markPlayed]
        // Default to .nextInList when absent (#629), same rationale as upNextInsertPosition above.
        playNextBehavior = try container.decodeIfPresent(PlayNextBehavior.self, forKey: .playNextBehavior) ?? .nextInList
        // Default to .distantPast when absent (predates #41), same rationale as autoArchiveRule
        // above — never lets a stale/missing timestamp beat a real one in an LWW comparison.
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
    }

    // Copies every field except the ones explicitly overridden. SettingsView's update*()
    // methods reconstruct an optimistic local UserSettings after changing just one field — with
    // a plain memberwise init, omitting any field (easy to do as more get added over time)
    // silently resets it to that init's default until the real server response arrives moments
    // later, which happened for real once already (playbackSpeed, before #179 fixed it). Routing
    // every such reconstruction through this method instead removes that whole bug class.
    func with(
        unlistenedEpisodeCount: UnlistenedEpisodeCount? = nil,
        autoArchiveRule: AutoArchiveRule? = nil,
        autoSkipIntroSeconds: Int? = nil,
        autoSkipOutroSeconds: Int? = nil,
        playbackSpeed: Float? = nil,
        autoDeleteRule: AutoDeleteRule? = nil,
        autoDeleteAfterDays: Int? = nil,
        autoDownloadNewEpisodes: Bool? = nil,
        smartSpeed: Bool? = nil,
        voiceBoost: Bool? = nil,
        notificationsEnabled: Bool? = nil,
        // Only ever used to set a picked duration (SleepTimerSheet), never to clear one back to
        // "unset" — a plain Int? param can't distinguish "omitted" from "explicitly nil" the way
        // every other field's own nil-means-unset case doesn't need to here, since this feature
        // never needs that distinction.
        sleepTimerDefaultDurationMinutes: Int? = nil,
        subscriptionSortOrder: SubscriptionSortOrder? = nil,
        subscriptionManualOrder: [String]? = nil,
        hideCaughtUpShows: Bool? = nil,
        autoAddNewEpisodesToUpNext: Bool? = nil,
        upNextInsertPosition: UpNextInsertPosition? = nil,
        leadingSwipeActions: [EpisodeSwipeAction]? = nil,
        trailingSwipeActions: [EpisodeSwipeAction]? = nil,
        playNextBehavior: PlayNextBehavior? = nil
    ) -> UserSettings {
        UserSettings(
            userId: userId, unlistenedEpisodeCount: unlistenedEpisodeCount ?? self.unlistenedEpisodeCount,
            version: version, autoArchiveRule: autoArchiveRule ?? self.autoArchiveRule,
            autoSkipIntroSeconds: autoSkipIntroSeconds ?? self.autoSkipIntroSeconds,
            autoSkipOutroSeconds: autoSkipOutroSeconds ?? self.autoSkipOutroSeconds,
            playbackSpeed: playbackSpeed ?? self.playbackSpeed,
            autoDeleteRule: autoDeleteRule ?? self.autoDeleteRule,
            autoDeleteAfterDays: autoDeleteAfterDays ?? self.autoDeleteAfterDays,
            autoDownloadNewEpisodes: autoDownloadNewEpisodes ?? self.autoDownloadNewEpisodes,
            smartSpeed: smartSpeed ?? self.smartSpeed,
            voiceBoost: voiceBoost ?? self.voiceBoost,
            notificationsEnabled: notificationsEnabled ?? self.notificationsEnabled,
            sleepTimerDefaultDurationMinutes: sleepTimerDefaultDurationMinutes ?? self.sleepTimerDefaultDurationMinutes,
            subscriptionSortOrder: subscriptionSortOrder ?? self.subscriptionSortOrder,
            subscriptionManualOrder: subscriptionManualOrder ?? self.subscriptionManualOrder,
            hideCaughtUpShows: hideCaughtUpShows ?? self.hideCaughtUpShows,
            autoAddNewEpisodesToUpNext: autoAddNewEpisodesToUpNext ?? self.autoAddNewEpisodesToUpNext,
            upNextInsertPosition: upNextInsertPosition ?? self.upNextInsertPosition,
            leadingSwipeActions: leadingSwipeActions ?? self.leadingSwipeActions,
            trailingSwipeActions: trailingSwipeActions ?? self.trailingSwipeActions,
            playNextBehavior: playNextBehavior ?? self.playNextBehavior,
            updatedAt: updatedAt)
    }
}

// How many unlistened episodes to surface per show. Mirrors the API's
// Kuulla.Api.Models.UnlistenedEpisodeCount enum, including its raw values, since the wire
// format is a plain integer.
enum UnlistenedEpisodeCount: Int, Codable, CaseIterable, Identifiable {
    case one = 1
    case two = 2
    case five = 5
    case ten = 10
    case unlimited = -1

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .one: "1 episode"
        case .two: "2 episodes"
        case .five: "5 episodes"
        case .ten: "10 episodes"
        case .unlimited: "All episodes"
        }
    }
}

// Which end of the "Up Next" queue an auto-added new episode is placed at (#440). Mirrors the
// API's Kuulla.Api.Models.UpNextInsertPosition enum, including its raw values, since the wire
// format is a plain integer. Bottom is 0 so a settings document that predates this field
// decodes as .bottom.
enum UpNextInsertPosition: Int, Codable, CaseIterable, Identifiable {
    case bottom = 0
    case top = 1

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .bottom: "Bottom of the queue"
        case .top: "Top of the queue"
        }
    }
}

// What plays when an episode finishes (#629): the next item of the list playback was started
// from (a show's episode list in its current sort/filter, a manual or dynamic playlist, Up Next,
// or New Episodes), that list's first item, or nothing. Mirrors the API's
// Kuulla.Core.Models.PlayNextBehavior enum, including its raw values, since the wire format is
// a plain integer. Resolved per finish by PlaybackQueue: playlist override → show override →
// this global value.
enum PlayNextBehavior: Int, Codable, CaseIterable, Identifiable {
    case nextInList = 0
    case topOfList = 1
    case stop = 2

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .nextInList: "Play the next episode in the list"
        case .topOfList: "Play from the top of the list"
        case .stop: "Stop"
        }
    }
}

// A quick action offered on an episode-list row's swipe gesture (#568). Mirrors the API's
// Kuulla.Core.Models.EpisodeSwipeAction enum, including its raw values, since the wire format
// is a plain integer.
enum EpisodeSwipeAction: Int, Codable, CaseIterable, Identifiable {
    case markPlayed = 0
    case addToPlaylist = 1
    case download = 2
    case addToUpNext = 3

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .markPlayed: "Mark as Played"
        case .addToPlaylist: "Add to Playlist"
        case .download: "Download"
        case .addToUpNext: "Add to Up Next"
        }
    }
}
