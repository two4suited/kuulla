import SwiftData
import XCTest
@testable import Kuulla

final class PlaylistSummaryTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: SyncCursor.self, PlaylistRecord.self, PendingPlaylistDownloadRecord.self,
            configurations: configuration)
        return ModelContext(container)
    }

    private func record(
        id: String, name: String, itemCount: Int = 0, deleted: Bool = false,
        icon: String? = nil, accentColor: String? = nil
    ) -> PlaylistRecord {
        let items = (0..<itemCount).map {
            PlaylistItemRecord(episodeId: "\(id)-ep\($0)", showId: "show", addedAt: .distantPast, order: "m")
        }
        return PlaylistRecord(
            id: id, name: name, type: .manual, items: items,
            createdAt: .distantPast, updatedAt: .distantPast, icon: icon, accentColor: accentColor, deleted: deleted)
    }

    func testListSortsByNameCaseInsensitively() throws {
        let context = try makeContext()
        for r in [record(id: "1", name: "zeta"), record(id: "2", name: "Alpha"), record(id: "3", name: "beta")] {
            context.insert(r)
        }

        let summaries = PlaylistSummary.list(
            from: try context.fetch(FetchDescriptor<PlaylistRecord>()), excludingUpNext: false)

        XCTAssertEqual(summaries.map(\.name), ["Alpha", "beta", "zeta"])
    }

    func testListDropsTombstonedRecords() throws {
        let context = try makeContext()
        context.insert(record(id: "1", name: "Live"))
        context.insert(record(id: "2", name: "Gone", deleted: true))

        let summaries = PlaylistSummary.list(
            from: try context.fetch(FetchDescriptor<PlaylistRecord>()), excludingUpNext: false)

        XCTAssertEqual(summaries.map(\.id), ["1"])
    }

    func testExcludingUpNextDropsOnlyTheQueuePlaylist() throws {
        let context = try makeContext()
        context.insert(record(id: "1", name: "Commute"))
        context.insert(record(id: "2", name: UpNextView.upNextPlaylistName))

        let excluded = PlaylistSummary.list(
            from: try context.fetch(FetchDescriptor<PlaylistRecord>()), excludingUpNext: true)
        XCTAssertEqual(excluded.map(\.name), ["Commute"])

        let included = PlaylistSummary.list(
            from: try context.fetch(FetchDescriptor<PlaylistRecord>()), excludingUpNext: false)
        XCTAssertEqual(Set(included.map(\.name)), [UpNextView.upNextPlaylistName, "Commute"])
    }

    func testSummaryCarriesItemCountAndAppearance() throws {
        let context = try makeContext()
        context.insert(record(id: "1", name: "Faves", itemCount: 3, icon: "🎧", accentColor: "#FF0000"))

        let summary = try XCTUnwrap(PlaylistSummary.list(
            from: try context.fetch(FetchDescriptor<PlaylistRecord>()), excludingUpNext: false).first)

        XCTAssertEqual(summary.itemCount, 3)
        XCTAssertEqual(summary.icon, "🎧")
        XCTAssertEqual(summary.accentColor, "#FF0000")
    }

    func testInitFromPlaylistWireModel() {
        let playlist = Playlist(
            id: "p1", userId: "u1", name: "Weekend", type: .manual,
            items: [PlaylistItemRecord(episodeId: "ep1", showId: "s1", addedAt: .distantPast, order: "m")],
            createdAt: .distantPast, updatedAt: .distantPast, dynamicConfig: nil, icon: "📻", accentColor: "#00FF00")

        let summary = PlaylistSummary(playlist: playlist)

        XCTAssertEqual(summary.id, "p1")
        XCTAssertEqual(summary.name, "Weekend")
        XCTAssertEqual(summary.itemCount, 1)
        XCTAssertEqual(summary.icon, "📻")
        XCTAssertEqual(summary.accentColor, "#00FF00")
    }
}
