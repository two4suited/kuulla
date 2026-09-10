import SwiftData
import XCTest
@testable import Kuulla

final class CatalogCacheTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: SubscriptionRecord.self, ShowRecord.self, CachedEpisodeRecord.self,
            ShowEpisodePageRecord.self, CatalogCacheState.self,
            configurations: configuration)
        return ModelContext(container)
    }

    private func subscription(id: String, showId: String) -> Subscription {
        Subscription(
            id: id, userId: "u1", showId: showId, showTitle: "Show \(showId)", showAuthor: "Author",
            showArtworkUrl: nil, subscribedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    private func episode(id: String, showId: String) -> Episode {
        Episode(
            id: id, showId: showId, title: "Episode \(id)",
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000), duration: 2_730,
            audioUrl: "https://example.com/\(id).mp3", description: "desc", bitrateKbps: 128,
            fileSizeBytes: 1_234, chapters: nil, transcriptUrl: nil, transcriptType: nil)
    }

    func testReplaceSubscriptionsUpsertsAndPrunes() throws {
        let context = try makeContext()

        CatalogCache.replaceSubscriptions(
            [subscription(id: "s1", showId: "show1"), subscription(id: "s2", showId: "show2")],
            in: context)
        XCTAssertEqual(Set(CatalogCache.subscriptions(in: context).map(\.showId)), ["show1", "show2"])

        // s2 unsubscribed elsewhere, s3 added — the local set should follow the server exactly.
        CatalogCache.replaceSubscriptions(
            [subscription(id: "s1", showId: "show1"), subscription(id: "s3", showId: "show3")],
            in: context)
        XCTAssertEqual(Set(CatalogCache.subscriptions(in: context).map(\.showId)), ["show1", "show3"])
    }

    func testUpsertAndRemoveSubscription() throws {
        let context = try makeContext()

        CatalogCache.upsertSubscription(subscription(id: "s1", showId: "show1"), in: context)
        XCTAssertEqual(CatalogCache.subscriptions(in: context).count, 1)

        CatalogCache.removeSubscription(showId: "show1", in: context)
        XCTAssertTrue(CatalogCache.subscriptions(in: context).isEmpty)
    }

    func testReplaceEpisodesKeepsServerOrderAndResetsOnRefresh() throws {
        let context = try makeContext()

        CatalogCache.replaceEpisodes(
            showId: "show1",
            [episode(id: "e1", showId: "show1"), episode(id: "e2", showId: "show1"), episode(id: "e3", showId: "show1")],
            continuationToken: "tok", in: context)
        XCTAssertEqual(CatalogCache.episodes(showId: "show1", in: context).map(\.id), ["e1", "e2", "e3"])
        XCTAssertEqual(CatalogCache.continuationToken(showId: "show1", in: context), "tok")

        // A refresh returns a shorter list — stale rows must be dropped, not merged.
        CatalogCache.replaceEpisodes(
            showId: "show1", [episode(id: "e9", showId: "show1")], continuationToken: nil, in: context)
        XCTAssertEqual(CatalogCache.episodes(showId: "show1", in: context).map(\.id), ["e9"])
        XCTAssertNil(CatalogCache.continuationToken(showId: "show1", in: context))
    }

    func testAppendEpisodesAddsAfterExistingWithoutDuplicates() throws {
        let context = try makeContext()

        CatalogCache.replaceEpisodes(
            showId: "show1", [episode(id: "e1", showId: "show1"), episode(id: "e2", showId: "show1")],
            continuationToken: "p2", in: context)
        CatalogCache.appendEpisodes(
            showId: "show1", [episode(id: "e2", showId: "show1"), episode(id: "e3", showId: "show1")],
            continuationToken: nil, in: context)

        XCTAssertEqual(CatalogCache.episodes(showId: "show1", in: context).map(\.id), ["e1", "e2", "e3"])
        XCTAssertNil(CatalogCache.continuationToken(showId: "show1", in: context))
    }

    func testEpisodeBridgeRoundTripsDurationAndChapters() throws {
        let context = try makeContext()
        let withChapters = Episode(
            id: "e1", showId: "show1", title: "Chaptered", publishedAt: nil, duration: 3_661,
            audioUrl: "https://example.com/e1.mp3", description: nil, bitrateKbps: nil,
            fileSizeBytes: nil,
            chapters: [
                EpisodeChapter(startTime: 0, title: "Intro", imageUrl: nil, url: nil),
                EpisodeChapter(startTime: 90, title: "Topic", imageUrl: "https://img", url: "https://u"),
            ],
            transcriptUrl: "https://t", transcriptType: "text/vtt")

        CatalogCache.replaceEpisodes(showId: "show1", [withChapters], continuationToken: nil, in: context)
        let restored = try XCTUnwrap(CatalogCache.episodes(showId: "show1", in: context).first)

        XCTAssertEqual(restored.duration, 3_661)
        XCTAssertEqual(restored.transcriptType, "text/vtt")
        XCTAssertEqual(restored.chapters?.map(\.title), ["Intro", "Topic"])
        XCTAssertEqual(restored.chapters?.last?.startTime, 90)
        XCTAssertEqual(restored.chapters?.last?.imageUrl, "https://img")
    }

    func testSnapshotStoreAndRead() throws {
        let context = try makeContext()
        let refreshedAt = Date(timeIntervalSince1970: 1_700_500_000)

        CatalogCache.storeSnapshot(
            unplayedCounts: ["show1": .init(unplayed: 3, hitCap: false), "show2": .init(unplayed: 12, hitCap: true)],
            inProgressShowIds: ["show3"],
            refreshedAt: refreshedAt, in: context)

        let counts = CatalogCache.unplayedCounts(in: context)
        XCTAssertEqual(counts["show1"]?.unplayed, 3)
        XCTAssertEqual(counts["show2"]?.hitCap, true)
        XCTAssertEqual(CatalogCache.inProgressShowIds(in: context), ["show3"])
        XCTAssertEqual(CatalogCache.lastRefreshedAt(in: context), refreshedAt)
    }

    func testStoreSnapshotWithNilRefreshedAtKeepsPreviousClock() throws {
        let context = try makeContext()
        let first = Date(timeIntervalSince1970: 1_700_000_000)

        CatalogCache.storeSnapshot(
            unplayedCounts: ["show1": .init(unplayed: 1, hitCap: false)],
            inProgressShowIds: [], refreshedAt: first, in: context)

        // A later partial sync: newer badge data, but refreshedAt nil (something failed).
        CatalogCache.storeSnapshot(
            unplayedCounts: ["show1": .init(unplayed: 4, hitCap: false)],
            inProgressShowIds: [], refreshedAt: nil, in: context)

        XCTAssertEqual(CatalogCache.unplayedCounts(in: context)["show1"]?.unplayed, 4)
        XCTAssertEqual(CatalogCache.lastRefreshedAt(in: context), first)
    }

    func testEpisodeStalenessHelpers() throws {
        let context = try makeContext()
        XCTAssertFalse(CatalogCache.hasEpisodes(showId: "show1", in: context))
        XCTAssertNil(CatalogCache.newestEpisodeDate(showId: "show1", in: context))

        let older = episode(id: "e1", showId: "show1")
        let newer = Episode(
            id: "e2", showId: "show1", title: "Newer",
            publishedAt: Date(timeIntervalSince1970: 1_700_100_000), duration: nil,
            audioUrl: "https://example.com/e2.mp3", description: nil, bitrateKbps: nil,
            fileSizeBytes: nil, chapters: nil, transcriptUrl: nil, transcriptType: nil)
        CatalogCache.replaceEpisodes(showId: "show1", [older, newer], continuationToken: nil, in: context)

        XCTAssertTrue(CatalogCache.hasEpisodes(showId: "show1", in: context))
        XCTAssertEqual(
            CatalogCache.newestEpisodeDate(showId: "show1", in: context),
            Date(timeIntervalSince1970: 1_700_100_000))
    }

    func testReadHelpersDoNotCreateStateRow() throws {
        let context = try makeContext()
        _ = CatalogCache.unplayedCounts(in: context)
        _ = CatalogCache.inProgressShowIds(in: context)
        _ = CatalogCache.lastRefreshedAt(in: context)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CatalogCacheState>()), 0)
    }

    func testEmptyCacheReadsAreHarmless() throws {
        let context = try makeContext()
        XCTAssertTrue(CatalogCache.subscriptions(in: context).isEmpty)
        XCTAssertTrue(CatalogCache.episodes(showId: "nope", in: context).isEmpty)
        XCTAssertTrue(CatalogCache.unplayedCounts(in: context).isEmpty)
        XCTAssertTrue(CatalogCache.inProgressShowIds(in: context).isEmpty)
        XCTAssertNil(CatalogCache.lastRefreshedAt(in: context))
        XCTAssertNil(CatalogCache.show(id: "nope", in: context))
    }
}
