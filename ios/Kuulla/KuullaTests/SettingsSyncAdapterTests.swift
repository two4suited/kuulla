import SwiftData
import XCTest
@testable import Kuulla

final class SettingsSyncAdapterTests: MockedApiTestCase {
    private func makeContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: SyncCursor.self, UserSettingsRecord.self, configurations: configuration)
    }

    private func stubSync(serverChanges: String = "[]", syncedAt: String = "2026-08-19T10:00:00Z", hash: String = "h1") {
        let json = """
        {"serverChanges":\(serverChanges),"syncedAt":"\(syncedAt)","hash":"\(hash)"}
        """.data(using: .utf8)!
        MockURLProtocol.stubHandler = { _ in .success(.init(statusCode: 200, data: json, headers: [:])) }
    }

    private func makeSettings(playbackSpeed: Float = 1.0, updatedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> UserSettings {
        UserSettings(
            userId: "u1", unlistenedEpisodeCount: .five, version: 1, autoArchiveRule: .never,
            playbackSpeed: playbackSpeed, updatedAt: updatedAt)
    }

    func testSyncNowSendsDirtySettingsInRequestBody() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(UserSettingsRecord(from: makeSettings(playbackSpeed: 1.5), isDirty: true))
        try context.save()

        var capturedBody: Data?
        let json = """
        {"serverChanges":[],"syncedAt":"2026-08-19T10:00:00Z","hash":"h1"}
        """.data(using: .utf8)!
        MockURLProtocol.stubHandler = { request in
            capturedBody = request.capturedBodyData
            return .success(.init(statusCode: 200, data: json, headers: [:]))
        }

        let engine = SyncEngine(modelContainer: container, adapter: SettingsSyncAdapter(apiClient: apiClient), deviceId: "device-1")
        await engine.syncNow()

        let requestedURL = try XCTUnwrap(MockURLProtocol.requestedURLs.first)
        XCTAssertTrue(requestedURL.absoluteString.hasSuffix("/api/sync/settings"))

        let bodyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(capturedBody)) as? [String: Any])
        XCTAssertEqual(bodyJSON["deviceId"] as? String, "device-1")
        let changes = try XCTUnwrap(bodyJSON["changes"] as? [[String: Any]])
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?["playbackSpeed"] as? Float, 1.5)

        let verifyContext = ModelContext(container)
        let stored = try XCTUnwrap(try verifyContext.fetch(FetchDescriptor<UserSettingsRecord>()).first)
        XCTAssertFalse(stored.isDirty)
    }

    func testSyncNowAppliesServerChangesIntoLocalStore() async throws {
        let container = try makeContainer()

        stubSync(
            serverChanges: """
            [{"unlistenedEpisodeCount":10,"version":2,"autoArchiveRule":1,"autoSkipIntroSeconds":0,"autoSkipOutroSeconds":0,"playbackSpeed":2.0,"autoDeleteRule":0,"autoDeleteAfterDays":7,"autoDownloadNewEpisodes":true,"smartSpeed":true,"updatedAt":"2026-08-19T09:00:00Z"}]
            """,
            hash: "h2")
        let engine = SyncEngine(modelContainer: container, adapter: SettingsSyncAdapter(apiClient: apiClient), deviceId: "device-1")

        await engine.syncNow()

        let verifyContext = ModelContext(container)
        let stored = try XCTUnwrap(try verifyContext.fetch(FetchDescriptor<UserSettingsRecord>()).first)
        XCTAssertEqual(stored.id, UserSettingsRecord.localId)
        XCTAssertEqual(stored.playbackSpeed, 2.0)
        XCTAssertTrue(stored.autoDownloadNewEpisodes)
        XCTAssertTrue(stored.smartSpeed)
        XCTAssertFalse(stored.isDirty)
    }

    func testApplyDiscardsServerChangeOlderThanStoredRecord() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let newer = Date(timeIntervalSince1970: 2_000_000_000)
        context.insert(UserSettingsRecord(from: makeSettings(playbackSpeed: 1.8, updatedAt: newer)))
        try context.save()

        let adapter = SettingsSyncAdapter(apiClient: apiClient)
        let stale = UserSettingsRecord(from: makeSettings(playbackSpeed: 0.5, updatedAt: Date(timeIntervalSince1970: 1_000_000_000)))

        try adapter.apply(stale, in: context)

        let stored = try XCTUnwrap(try context.fetch(FetchDescriptor<UserSettingsRecord>()).first)
        XCTAssertEqual(stored.playbackSpeed, 1.8)
    }
}
