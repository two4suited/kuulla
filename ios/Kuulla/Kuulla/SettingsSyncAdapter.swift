import Foundation
import SwiftData

// SyncAdapter for UserSettingsRecord, calling POST /api/sync/settings
// (src/Kuulla.Api/Program.cs, reconciliation protocol documented in docs/sync-conventions.md).
// Mirrors EpisodeSyncAdapter.swift's structure — see its comments for the shared rationale.
//
// Unlike episodes, SettingsView.swift never marks a UserSettingsRecord dirty: it writes through
// the API's field-specific PUT endpoints directly (so the server-side enforcement side effects
// those endpoints trigger — unlistened-episode-limit and auto-archive enforcement — still run,
// which the generic sync endpoint does not do) and only mirrors the accepted response into this
// record with isDirty: false. So push()'s dirty-record branch below is exercised by
// SettingsSyncAdapterTests but not by the running app — SyncEngine.syncNow() here only ever
// pulls (an empty-changes poll). Kept for framework consistency and in case a future write path
// needs a genuine local-first push.
struct SettingsSyncAdapter: SyncAdapter {
    let domain = "settings"

    private let apiClient: ApiClient

    init(apiClient: ApiClient = .shared) {
        self.apiClient = apiClient
    }

    func push(
        deviceId: String,
        lastSyncedAt: Date,
        localHash: String,
        dirtyRecords: [UserSettingsRecord]
    ) async throws -> SyncPushResult<UserSettingsRecord> {
        // At most one dirty record ever exists — a device only ever has one UserSettingsRecord.
        let changes = dirtyRecords.prefix(1).map {
            UserSettingsChangeDTO(
                unlistenedEpisodeCount: $0.unlistenedEpisodeCount,
                autoArchiveRule: $0.autoArchiveRule,
                autoSkipIntroSeconds: $0.autoSkipIntroSeconds,
                autoSkipOutroSeconds: $0.autoSkipOutroSeconds,
                playbackSpeed: $0.playbackSpeed,
                autoDeleteRule: $0.autoDeleteRule,
                autoDeleteAfterDays: $0.autoDeleteAfterDays,
                autoDownloadNewEpisodes: $0.autoDownloadNewEpisodes,
                smartSpeed: $0.smartSpeed,
                notificationsEnabled: $0.notificationsEnabled,
                sleepTimerDefaultDurationMinutes: $0.sleepTimerDefaultDurationMinutes,
                subscriptionSortOrder: $0.subscriptionSortOrder,
                subscriptionManualOrder: $0.subscriptionManualOrder,
                hideCaughtUpShows: $0.hideCaughtUpShows,
                autoAddNewEpisodesToUpNext: $0.autoAddNewEpisodesToUpNext,
                upNextInsertPosition: $0.upNextInsertPosition,
                leadingSwipeActions: $0.leadingSwipeActions,
                trailingSwipeActions: $0.trailingSwipeActions,
                playNextBehavior: $0.playNextBehavior,
                updatedAt: $0.updatedAt)
        }
        let request = SyncSettingsRequestDTO(
            deviceId: deviceId, lastSyncedAt: lastSyncedAt, localHash: localHash, changes: Array(changes))

        let result: SyncSettingsResultDTO = try await apiClient.post(["api", "sync", "settings"], body: request)

        let serverChanges = result.serverChanges.map(\.asRecord)
        return SyncPushResult(serverChanges: serverChanges, syncedAt: result.syncedAt, hash: result.hash)
    }

    func apply(_ record: UserSettingsRecord, in context: ModelContext) throws {
        let id = record.id
        let existing = try context.fetch(FetchDescriptor<UserSettingsRecord>(
            predicate: #Predicate { $0.id == id }
        )).first

        if let existing {
            // Last-write-wins, same rationale as EpisodeSyncAdapter.apply.
            guard record.updatedAt > existing.updatedAt else { return }
            existing.apply(record)
        } else {
            context.insert(record)
        }
    }
}

private struct UserSettingsChangeDTO: Encodable {
    let unlistenedEpisodeCount: UnlistenedEpisodeCount
    let autoArchiveRule: AutoArchiveRule
    let autoSkipIntroSeconds: Int
    let autoSkipOutroSeconds: Int
    let playbackSpeed: Float
    let autoDeleteRule: AutoDeleteRule
    let autoDeleteAfterDays: Int
    let autoDownloadNewEpisodes: Bool
    let smartSpeed: Bool
    let notificationsEnabled: Bool
    let sleepTimerDefaultDurationMinutes: Int?
    // Non-optional (unlike the API's nullable UserSettingsChange.SubscriptionSortOrder) — this
    // client always knows the field and always sends it, so there's no "omit to keep stored".
    let subscriptionSortOrder: SubscriptionSortOrder
    // Always sent (this DTO can't express null). An empty array means "this device has no
    // manual arrangement"; the server treats null and empty alike here and keeps whatever's
    // stored, so a device that never used Manual mode can't wipe another device's order.
    let subscriptionManualOrder: [String]
    // Non-optional — this client always knows the field and always sends it (the API's
    // UserSettingsChange.HideCaughtUpShows is nullable only for older clients that omit it).
    let hideCaughtUpShows: Bool
    let autoAddNewEpisodesToUpNext: Bool
    let upNextInsertPosition: UpNextInsertPosition
    // Always sent (this DTO can't express null) — this client always knows the field and always
    // sends it (#568). Unlike subscriptionManualOrder, the server does NOT special-case an empty
    // array here: it's applied as a deliberate "no actions on this side" (#571). This path is
    // unreachable today (see this file's header comment) since nothing marks a UserSettingsRecord
    // dirty, so that distinction has no live effect yet.
    let leadingSwipeActions: [EpisodeSwipeAction]
    let trailingSwipeActions: [EpisodeSwipeAction]
    // Non-optional — this client always knows the field (#629); the API's nullable
    // UserSettingsChange.PlayNextBehavior only exists for older clients that omit it.
    let playNextBehavior: PlayNextBehavior
    let updatedAt: Date
}

private struct SyncSettingsRequestDTO: Encodable {
    let deviceId: String
    let lastSyncedAt: Date
    let localHash: String
    let changes: [UserSettingsChangeDTO]
}

private struct SyncSettingsResultDTO: Decodable {
    let serverChanges: [UserSettingsDTO]
    let syncedAt: Date
    let hash: String
}

// Mirrors src/Kuulla.Api/Models/UserSettings.cs's wire shape (a subset of UserSettings.swift's
// own decoder — kept separate since this one always requires updatedAt, whereas the top-level
// model's decoder tolerates it being absent for pre-#41 responses).
private struct UserSettingsDTO: Decodable {
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
    let notificationsEnabled: Bool
    let sleepTimerDefaultDurationMinutes: Int?
    let subscriptionSortOrder: SubscriptionSortOrder
    // Optional so a response that omits it or sends null (the API default) still decodes.
    let subscriptionManualOrder: [String]?
    // Optional so a response that predates this field still decodes; defaults to false.
    let hideCaughtUpShows: Bool?
    // Optional so a response from an API that predates #440 still decodes; asRecord falls back.
    let autoAddNewEpisodesToUpNext: Bool?
    let upNextInsertPosition: UpNextInsertPosition?
    // Optional so a response from an API that predates #568 still decodes; asRecord falls back.
    let leadingSwipeActions: [EpisodeSwipeAction]?
    let trailingSwipeActions: [EpisodeSwipeAction]?
    // Optional so a response from an API that predates #629 still decodes; asRecord falls back.
    let playNextBehavior: PlayNextBehavior?
    let updatedAt: Date

    var asRecord: UserSettingsRecord {
        UserSettingsRecord(
            unlistenedEpisodeCount: unlistenedEpisodeCount, autoArchiveRule: autoArchiveRule,
            autoSkipIntroSeconds: autoSkipIntroSeconds, autoSkipOutroSeconds: autoSkipOutroSeconds, playbackSpeed: playbackSpeed,
            autoDeleteRule: autoDeleteRule, autoDeleteAfterDays: autoDeleteAfterDays, autoDownloadNewEpisodes: autoDownloadNewEpisodes,
            smartSpeed: smartSpeed, notificationsEnabled: notificationsEnabled,
            sleepTimerDefaultDurationMinutes: sleepTimerDefaultDurationMinutes,
            subscriptionSortOrder: subscriptionSortOrder, subscriptionManualOrder: subscriptionManualOrder ?? [],
            hideCaughtUpShows: hideCaughtUpShows ?? false,
            autoAddNewEpisodesToUpNext: autoAddNewEpisodesToUpNext ?? false,
            upNextInsertPosition: upNextInsertPosition ?? .bottom,
            leadingSwipeActions: leadingSwipeActions ?? [],
            trailingSwipeActions: trailingSwipeActions ?? [.addToPlaylist, .markPlayed],
            playNextBehavior: playNextBehavior ?? .nextInList,
            version: version, updatedAt: updatedAt)
    }
}
