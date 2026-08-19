import XCTest
@testable import Kuulla

final class EpisodeStatusTests: XCTestCase {
    func testNilRecordIsNew() {
        XCTAssertEqual(EpisodeStatus(record: nil), .new)
    }

    func testZeroPositionUncompletedRecordIsNew() {
        let record = EpisodeStateRecord(id: "ep1", showId: "show1", positionSeconds: 0, completed: false, updatedAt: Date())
        XCTAssertEqual(EpisodeStatus(record: record), .new)
    }

    func testPositiveUncompletedPositionIsInProgress() {
        let record = EpisodeStateRecord(id: "ep1", showId: "show1", positionSeconds: 42, completed: false, updatedAt: Date())
        XCTAssertEqual(EpisodeStatus(record: record), .inProgress)
    }

    func testCompletedRecordIsPlayed() {
        let record = EpisodeStateRecord(id: "ep1", showId: "show1", positionSeconds: 1200, completed: true, updatedAt: Date())
        XCTAssertEqual(EpisodeStatus(record: record), .played)
    }

    func testCompletedTakesPrecedenceOverPosition() {
        // A completed record with position 0 (e.g. explicitly re-marked played from the start)
        // should still read as played, not new.
        let record = EpisodeStateRecord(id: "ep1", showId: "show1", positionSeconds: 0, completed: true, updatedAt: Date())
        XCTAssertEqual(EpisodeStatus(record: record), .played)
    }
}
