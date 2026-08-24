import Foundation
import SwiftData

// SyncAdapter for UserSettingsRecord, calling POST /api/sync/settings
// (src/Kuulla.Api/Program.cs, reconciliation protocol documented in docs/sync-conventions.md).
// Mirrors EpisodeSyncAdapter.swift's structure — see its comments for the shared rationale.
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
                updatedAt: $0.updatedAt)
        }
        let request = SyncSettingsRequestDTO(
            deviceId: deviceId, lastSyncedAt: lastSyncedAt, localHash: localHash, changes: Array(changes))

        let result: SyncSettingsResultDTO = try await apiClient.post(["api", "sync", "settings"], body: request)

        let serverChanges = result.serverChanges.map { UserSettingsRecord(from: $0.asUserSettings) }
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
            existing.apply(record.asUserSettings)
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
    let updatedAt: Date

    var asUserSettings: UserSettings {
        UserSettings(
            userId: "", unlistenedEpisodeCount: unlistenedEpisodeCount, version: version, autoArchiveRule: autoArchiveRule,
            autoSkipIntroSeconds: autoSkipIntroSeconds, autoSkipOutroSeconds: autoSkipOutroSeconds, playbackSpeed: playbackSpeed,
            autoDeleteRule: autoDeleteRule, autoDeleteAfterDays: autoDeleteAfterDays, autoDownloadNewEpisodes: autoDownloadNewEpisodes,
            updatedAt: updatedAt)
    }
}
