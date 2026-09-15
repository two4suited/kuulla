import SwiftData
import XCTest
@testable import Kuulla

@MainActor
final class CatalogRefreshServiceTests: MockedApiTestCase {
    private func makeContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: SyncCursor.self, EpisodeStateRecord.self, PlaylistRecord.self, DownloadedEpisodeRecord.self,
            UserSettingsRecord.self,
            SubscriptionRecord.self, ShowRecord.self, CachedEpisodeRecord.self,
            CachedNewEpisodeRecord.self, ShowEpisodePageRecord.self, CatalogCacheState.self,
            configurations: configuration)
    }

    private func makeService(container: ModelContainer) -> CatalogRefreshService {
        CatalogRefreshService(
            modelContainer: container,
            episodeSyncEngine: SyncEngine(modelContainer: container, adapter: EpisodeSyncAdapter(apiClient: apiClient)),
            playlistSyncEngine: SyncEngine(modelContainer: container, adapter: PlaylistSyncAdapter(apiClient: apiClient)),
            settingsSyncEngine: SyncEngine(modelContainer: container, adapter: SettingsSyncAdapter(apiClient: apiClient)),
            subscriptionClient: SubscriptionClient(apiClient: apiClient),
            catalogClient: PodcastCatalogClient(apiClient: apiClient))
    }

    // A subscribed show that's already fully cached (metadata + episodes, no newer episode on
    // the subscription) never lands in showIdsToRefresh, so before the #746 fix its metadata was
    // never re-fetched — a server-side title/artwork change would never reach the device.
    func testRefreshAllUpdatesMetadataForFullyCachedShowWithNoNewEpisode() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let publishedAt = Date(timeIntervalSince1970: 1_700_000_000)
        CatalogCache.upsertShow(
            Show(id: "show1", title: "Old Title", author: "A", feedUrl: "https://feed", artworkUrl: nil,
                 description: nil, categories: []),
            in: context)
        CatalogCache.replaceEpisodes(
            showId: "show1",
            [Episode(
                id: "ep1", showId: "show1", title: "Ep 1", publishedAt: publishedAt, duration: nil,
                audioUrl: "https://audio", description: nil, bitrateKbps: nil, fileSizeBytes: nil,
                chapters: nil, transcriptUrl: nil, transcriptType: nil)],
            continuationToken: nil, in: context)

        let subscriptionJson = """
        [{"id":"sub1","userId":"u1","showId":"show1","showTitle":"Old Title","showAuthor":"A",
          "showArtworkUrl":null,"subscribedAt":"2026-08-18T10:00:00+00:00",
          "latestEpisodePublishedAt":"2023-11-14T22:13:20+00:00"}]
        """.data(using: .utf8)!
        let showJson = """
        {"id":"show1","title":"New Title","author":"A","feedUrl":"https://feed","artworkUrl":"https://art",
         "description":"updated","categories":[]}
        """.data(using: .utf8)!
        let syncJson = """
        {"serverChanges":[],"syncedAt":"2026-08-18T10:00:00+00:00","hash":"h1"}
        """.data(using: .utf8)!

        MockURLProtocol.stubHandler = { request in
            let path = request.url?.path ?? ""
            switch path {
            case "/api/subscriptions":
                return .success(.init(statusCode: 200, data: subscriptionJson, headers: [:]))
            case "/api/subscriptions/episodes":
                return .success(.init(statusCode: 200, data: "[]".data(using: .utf8)!, headers: [:]))
            case "/api/episodes/in-progress-shows":
                return .success(.init(statusCode: 200, data: "[]".data(using: .utf8)!, headers: [:]))
            case "/api/shows/show1":
                return .success(.init(statusCode: 200, data: showJson, headers: [:]))
            case "/api/sync/episodes", "/api/sync/playlists", "/api/sync/settings":
                return .success(.init(statusCode: 200, data: syncJson, headers: [:]))
            default:
                XCTFail("unexpected request: \(path)")
                return .success(.init(statusCode: 404, data: Data(), headers: [:]))
            }
        }

        let service = makeService(container: container)
        await service.refreshAll()

        let verifyContext = ModelContext(container)
        let show = try XCTUnwrap(CatalogCache.show(id: "show1", in: verifyContext))
        XCTAssertEqual(show.title, "New Title")
        XCTAssertEqual(show.artworkUrl, "https://art")

        // Metadata-only refresh must not re-fetch the episode page for an already-cached show.
        XCTAssertFalse(MockURLProtocol.requestedURLs.contains { $0.path == "/api/shows/show1/episodes" })
    }
}
