import SwiftData
import XCTest
@testable import Kuulla

final class CatalogCacheTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: SubscriptionRecord.self, ShowRecord.self, CachedEpisodeRecord.self,
            CachedNewEpisodeRecord.self, ShowEpisodePageRecord.self, CatalogCacheState.self,
            EpisodeStateRecord.self,
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

    private func newEpisode(id: String, showId: String, autoPlayed: Bool = false) -> NewEpisode {
        NewEpisode(
            episode: episode(id: id, showId: showId), autoPlayed: autoPlayed,
            showTitle: "Show \(showId)", showArtworkUrl: "https://img/\(showId).jpg")
    }

    func testReplaceNewEpisodesKeepsServerOrderAndRoundTripsFields() throws {
        let context = try makeContext()

        CatalogCache.replaceNewEpisodes(
            [
                newEpisode(id: "e1", showId: "show1"),
                newEpisode(id: "e2", showId: "show2", autoPlayed: true),
                newEpisode(id: "e3", showId: "show1"),
            ],
            in: context)

        let cached = CatalogCache.newEpisodes(in: context)
        XCTAssertEqual(cached.map(\.episode.id), ["e1", "e2", "e3"])
        XCTAssertEqual(cached.map(\.autoPlayed), [false, true, false])
        XCTAssertEqual(cached[1].showTitle, "Show show2")
        XCTAssertEqual(cached[1].showArtworkUrl, "https://img/show2.jpg")
        XCTAssertEqual(cached[0].episode.duration, 2_730)
    }

    func testReplaceNewEpisodesDropsStaleRows() throws {
        let context = try makeContext()

        CatalogCache.replaceNewEpisodes(
            [newEpisode(id: "e1", showId: "show1"), newEpisode(id: "e2", showId: "show1")], in: context)
        CatalogCache.replaceNewEpisodes([newEpisode(id: "e9", showId: "show2")], in: context)

        XCTAssertEqual(CatalogCache.newEpisodes(in: context).map(\.episode.id), ["e9"])
    }

    // The common refresh path: the new list overlaps the old one (same episode ids). Delete +
    // re-insert of a unique id must survive a single save, and re-ordering must take effect.
    func testReplaceNewEpisodesHandlesOverlappingIdsAndReorders() throws {
        let context = try makeContext()

        CatalogCache.replaceNewEpisodes(
            [newEpisode(id: "e1", showId: "show1"), newEpisode(id: "e2", showId: "show1")], in: context)
        CatalogCache.replaceNewEpisodes(
            [newEpisode(id: "e2", showId: "show1"), newEpisode(id: "e1", showId: "show1")], in: context)

        XCTAssertEqual(CatalogCache.newEpisodes(in: context).map(\.episode.id), ["e2", "e1"])
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

    func testRemoveShowFromSnapshotDropsBadgeAndInProgressEntries() throws {
        let context = try makeContext()

        CatalogCache.storeSnapshot(
            unplayedCounts: [
                "show1": .init(unplayed: 3, hitCap: false),
                "show2": .init(unplayed: 5, hitCap: false),
            ],
            inProgressShowIds: ["show1", "show2"],
            refreshedAt: Date(timeIntervalSince1970: 1_700_500_000), in: context)

        CatalogCache.removeShowFromSnapshot(showId: "show1", in: context)

        XCTAssertNil(CatalogCache.unplayedCounts(in: context)["show1"])
        XCTAssertEqual(CatalogCache.unplayedCounts(in: context)["show2"]?.unplayed, 5)
        XCTAssertEqual(CatalogCache.inProgressShowIds(in: context), ["show2"])
    }

    func testRemoveShowFromSnapshotWithNoStateRowIsHarmless() throws {
        let context = try makeContext()
        CatalogCache.removeShowFromSnapshot(showId: "show1", in: context)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CatalogCacheState>()), 0)
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

    func testRecordEpisodeStateChangeMarkingPlayedDecrementsUnplayedAndClearsInProgress() throws {
        let context = try makeContext()
        CatalogCache.replaceNewEpisodes(
            [
                newEpisode(id: "e1", showId: "show1"), newEpisode(id: "e2", showId: "show1"),
                newEpisode(id: "e3", showId: "show1"),
            ],
            in: context)
        CatalogCache.storeSnapshot(
            unplayedCounts: ["show1": .init(unplayed: 3, hitCap: false)],
            inProgressShowIds: ["show1"],
            refreshedAt: Date(timeIntervalSince1970: 1_700_500_000), in: context)

        CatalogCache.recordEpisodeStateChange(
            episodeId: "e1", showId: "show1", completed: true, positionSeconds: 2_730, in: context)

        XCTAssertEqual(CatalogCache.unplayedCounts(in: context)["show1"]?.unplayed, 2)
        // No other episode of show1 is still in-progress, so it drops out of the set.
        XCTAssertEqual(CatalogCache.inProgressShowIds(in: context), [])
    }

    // Retoggling the same episode played -> unplayed -> played must land back at the same count,
    // not keep decrementing (#532 review fix — the original incremental-decrement version double
    // counted this).
    func testRecordEpisodeStateChangeRetoggleDoesNotCompoundTheCount() throws {
        let context = try makeContext()
        CatalogCache.replaceNewEpisodes(
            [newEpisode(id: "e1", showId: "show1"), newEpisode(id: "e2", showId: "show1")], in: context)
        CatalogCache.storeSnapshot(
            unplayedCounts: ["show1": .init(unplayed: 2, hitCap: false)],
            inProgressShowIds: [], refreshedAt: Date(timeIntervalSince1970: 1_700_500_000), in: context)

        CatalogCache.recordEpisodeStateChange(
            episodeId: "e1", showId: "show1", completed: true, positionSeconds: 2_730, in: context)
        XCTAssertEqual(CatalogCache.unplayedCounts(in: context)["show1"]?.unplayed, 1)

        // Undo — the badge should go right back up, unlike the old decrement-only behavior.
        CatalogCache.recordEpisodeStateChange(
            episodeId: "e1", showId: "show1", completed: false, positionSeconds: 0, in: context)
        XCTAssertEqual(CatalogCache.unplayedCounts(in: context)["show1"]?.unplayed, 2)

        CatalogCache.recordEpisodeStateChange(
            episodeId: "e1", showId: "show1", completed: true, positionSeconds: 2_730, in: context)
        XCTAssertEqual(CatalogCache.unplayedCounts(in: context)["show1"]?.unplayed, 1)
    }

    func testRecordEpisodeStateChangeRemovesUnplayedKeyWhenCountReachesZero() throws {
        let context = try makeContext()
        CatalogCache.replaceNewEpisodes([newEpisode(id: "e1", showId: "show1")], in: context)
        CatalogCache.storeSnapshot(
            unplayedCounts: ["show1": .init(unplayed: 1, hitCap: false)],
            inProgressShowIds: [], refreshedAt: Date(timeIntervalSince1970: 1_700_500_000), in: context)

        CatalogCache.recordEpisodeStateChange(
            episodeId: "e1", showId: "show1", completed: true, positionSeconds: 2_730, in: context)

        XCTAssertNil(CatalogCache.unplayedCounts(in: context)["show1"])
    }

    func testRecordEpisodeStateChangeDoesNotDecrementForUncountedEpisode() throws {
        // e1 was never part of the cached New Episodes feed (e.g. an older back-catalogue
        // episode) — marking it played shouldn't touch a badge count that never included it.
        let context = try makeContext()
        CatalogCache.storeSnapshot(
            unplayedCounts: ["show1": .init(unplayed: 3, hitCap: false)],
            inProgressShowIds: [], refreshedAt: Date(timeIntervalSince1970: 1_700_500_000), in: context)

        CatalogCache.recordEpisodeStateChange(
            episodeId: "e1", showId: "show1", completed: true, positionSeconds: 2_730, in: context)

        XCTAssertEqual(CatalogCache.unplayedCounts(in: context)["show1"]?.unplayed, 3)
    }

    func testRecordEpisodeStateChangeKeepsShowInProgressWhenAnotherEpisodeStillIs() throws {
        let context = try makeContext()
        context.insert(EpisodeStateRecord(
            id: "e2", showId: "show1", positionSeconds: 100, completed: false, updatedAt: .now))
        CatalogCache.storeSnapshot(
            unplayedCounts: [:], inProgressShowIds: ["show1"],
            refreshedAt: Date(timeIntervalSince1970: 1_700_500_000), in: context)

        CatalogCache.recordEpisodeStateChange(
            episodeId: "e1", showId: "show1", completed: true, positionSeconds: 2_730, in: context)

        XCTAssertEqual(CatalogCache.inProgressShowIds(in: context), ["show1"])
    }

    func testRecordEpisodeStateChangeAddsShowToInProgressOnPartialPlayback() throws {
        let context = try makeContext()
        CatalogCache.storeSnapshot(
            unplayedCounts: [:], inProgressShowIds: [],
            refreshedAt: Date(timeIntervalSince1970: 1_700_500_000), in: context)

        CatalogCache.recordEpisodeStateChange(
            episodeId: "e1", showId: "show1", completed: false, positionSeconds: 42, in: context)

        XCTAssertEqual(CatalogCache.inProgressShowIds(in: context), ["show1"])
    }

    func testRecordEpisodeStateChangeWithNoStateRowIsHarmless() throws {
        let context = try makeContext()
        CatalogCache.recordEpisodeStateChange(
            episodeId: "e1", showId: "show1", completed: true, positionSeconds: 0, in: context)
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
